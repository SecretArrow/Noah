import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../di.dart';
import '../../models/local_model.dart';
import 'local_model_io.dart';
import 'ollama_registry_client.dart';

/// Lifecycle of one download row — v1.51.0.
enum DownloadStatus { queued, running, paused, completed, failed, canceled }

/// One visible download row (state = one row per modelId). [error] is
/// null unless the status is failed.
class DownloadProgress {
  const DownloadProgress({
    required this.modelId,
    required this.modelName,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.status = DownloadStatus.queued,
    this.error,
  });

  final String modelId;
  final String modelName;
  final int receivedBytes;

  /// Expected total (0 = unknown until the server reports a length).
  final int totalBytes;
  final DownloadStatus status;
  final String? error;

  DownloadProgress copyWith({
    int? receivedBytes,
    int? totalBytes,
    DownloadStatus? status,
    String? error,
  }) => DownloadProgress(
    modelId: modelId,
    modelName: modelName,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    totalBytes: totalBytes ?? this.totalBytes,
    status: status ?? this.status,
    error: error ?? this.error,
  );
}

/// Pause/cancel intent set from the UI, observed by the transfer loop
/// on the next stream chunk (breaking out of the await-for cancels the
/// HTTP subscription, which closes the request).
enum _Signal { paused, canceled }

/// Everything needed to (re)run one transfer after it was resolved.
class _DownloadSpec {
  const _DownloadSpec(this.entry, this.url, this.expectedSha);

  final LocalModelEntry entry;
  final String url;

  /// Lowercase hex sha256 to verify against ('' = unknown, skip).
  final String expectedSha;
}

/// Incremental sha256 sink (crypto streaming): chunks are added as they
/// arrive from the network; [close] returns the lowercase hex digest.
class _Sha256Sink {
  _Sha256Sink._(this._events, this._hasher);

  factory _Sha256Sink() {
    final List<Digest> events = <Digest>[];
    return _Sha256Sink._(
      events,
      sha256.startChunkedConversion(_CollectorSink(events)),
    );
  }

  final List<Digest> _events;
  final Sink<List<int>> _hasher;

  void add(List<int> chunk) => _hasher.add(chunk);

  String close() {
    _hasher.close();
    return _events.single.toString();
  }
}

class _CollectorSink implements Sink<Digest> {
  _CollectorSink(this.events);

  final List<Digest> events;

  @override
  void add(Digest data) => events.add(data);

  @override
  void close() {}
}

/// Riverpod download queue for local models — v1.51.0.
///
/// State is the visible row list (one per modelId). Transfers stream
/// straight into `<modelsDir>/<fileName>.part` (append on resume) and
/// only rename to the final `<fileName>` after the sha256 verified, so
/// a broken download can never masquerade as an installed model.
/// Pause breaks out of the response stream (closing the request) and
/// keeps the `.part`; resume sends `Range: bytes=<part>-` — a 206
/// appends, a 200 restarts the file from scratch. Dependencies (http
/// client, models dir) are optional constructor params for direct unit
/// testing; production di constructs the controller bare and everything
/// resolves through the injectable providers.
class DownloadQueueController extends Notifier<List<DownloadProgress>> {
  DownloadQueueController({http.Client? httpClient, Directory? modelsDir})
    : _injectedClient = httpClient,
      _injectedDir = modelsDir;

  final http.Client? _injectedClient;
  final Directory? _injectedDir;

  /// Completed-download hook — wired (by default, in [build]) to the
  /// local-models controller's addInstalled so finished models appear
  /// in the Installed tab. Mutable so tests and the importer can
  /// capture enriched entries instead.
  void Function(LocalModelEntry)? onCompleted;

  /// Hard cap for establishing a download (headers); the body stream
  /// itself is allowed to trickle for the whole transfer.
  static const Duration connectTimeout = Duration(seconds: 30);

  /// Resolved-download bookkeeping per modelId (kept while a row can
  /// still be resumed).
  final Map<String, _DownloadSpec> _specs = <String, _DownloadSpec>{};

  /// Pause/cancel intents not yet observed by a transfer loop.
  final Map<String, _Signal> _signals = <String, _Signal>{};

  /// Wind-down future per modelId — resume must await it so a new
  /// transfer never races the old one's file handle.
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  Directory? _resolvedDir;

  @override
  List<DownloadProgress> build() {
    // Default di wiring: a verified download lands in the installed
    // list. Kept as a mutable field so tests (and any future wiring)
    // can observe or replace the hook.
    onCompleted ??= (LocalModelEntry entry) =>
        ref.read(localModelsProvider.notifier).addInstalled(entry);
    return const <DownloadProgress>[];
  }

  http.Client _client() {
    final http.Client? injected = _injectedClient;
    if (injected != null) return injected;
    return ref.read(llmHttpClientProvider);
  }

  Future<Directory> _resolveModelsDir() async {
    final Directory? injected = _injectedDir;
    if (injected != null) return injected;
    return _resolvedDir ??= await resolveLocalModelsDir();
  }

  DownloadProgress? _rowOf(String modelId) {
    for (final DownloadProgress row in state) {
      if (row.modelId == modelId) return row;
    }
    return null;
  }

  void _setRow(
    String modelId, {
    DownloadStatus? status,
    int? receivedBytes,
    int? totalBytes,
    String? error,
  }) {
    state = <DownloadProgress>[
      for (final DownloadProgress row in state)
        if (row.modelId == modelId)
          row.copyWith(
            status: status,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
            error: error,
          )
        else
          row,
    ];
  }

  void _upsertRow(DownloadProgress row) {
    bool replaced = false;
    final List<DownloadProgress> next = <DownloadProgress>[];
    for (final DownloadProgress existing in state) {
      if (existing.modelId == row.modelId) {
        next.add(row);
        replaced = true;
      } else {
        next.add(existing);
      }
    }
    if (!replaced) next.add(row);
    state = next;
  }

  Future<void> _tryDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Already gone or locked: best-effort cleanup.
    }
  }

  /// Awaits the completion hook without letting a failing store update
  /// surface as an unhandled async error (the download itself already
  /// succeeded at this point).
  Future<void> _notifyCompleted(LocalModelEntry entry) async {
    final void Function(LocalModelEntry)? callback = onCompleted;
    if (callback == null) return;
    try {
      final Object? outcome = Function.apply(callback, <Object?>[entry]);
      if (outcome is Future) await outcome;
    } catch (_) {
      // The completion hook must never break finalization.
    }
  }

  /// Queues [entry] for download. The entry is pre-built by the UI
  /// (catalog ref or custom URL); the queue resolves the concrete URL
  /// and expected sha256 (registry digest, or the entry's own sha256
  /// for custom URLs), adds a row and starts the transfer — the future
  /// completes once the transfer is UNDER WAY, not when it finishes
  /// (progress and outcome are observed through the provider state).
  Future<void> enqueue(LocalModelEntry entry) async {
    final DownloadProgress? existing = _rowOf(entry.id);
    if (existing != null &&
        (existing.status == DownloadStatus.queued ||
            existing.status == DownloadStatus.running ||
            existing.status == DownloadStatus.paused)) {
      return; // Already queued/in flight/paused — resume drives those.
    }

    // TODO(v1.52.0): free-disk guard — dart:io exposes no statfs-style
    // free-space API, so the queue cannot pre-check the models dir.
    // ENOSPC write failures already degrade to a failed row; do not
    // invent a platform API here.

    final String customUrl = entry.customUrl.trim();
    final String registryRef = entry.ollamaRef.trim();
    String url;
    String expectedSha;
    int totalBytes = 0;
    if (customUrl.isNotEmpty) {
      url = customUrl;
      expectedSha = entry.sha256.trim().toLowerCase();
      totalBytes = entry.sizeBytes;
    } else if (registryRef.isNotEmpty) {
      final RegistryBlob blob;
      try {
        blob = await ref
            .read(ollamaRegistryClientProvider)
            .resolve(registryRef);
      } on OllamaRegistryException catch (error) {
        _upsertRow(
          DownloadProgress(
            modelId: entry.id,
            modelName: entry.name,
            status: DownloadStatus.failed,
            error: 'registry: $error',
          ),
        );
        return;
      } catch (error) {
        _upsertRow(
          DownloadProgress(
            modelId: entry.id,
            modelName: entry.name,
            status: DownloadStatus.failed,
            error: 'registry: $error',
          ),
        );
        return;
      }
      url = blob.blobUrl;
      expectedSha = entry.sha256.trim().isNotEmpty
          ? entry.sha256.trim().toLowerCase()
          : blob.sha256.toLowerCase();
      totalBytes = blob.sizeBytes;
    } else {
      _upsertRow(
        DownloadProgress(
          modelId: entry.id,
          modelName: entry.name,
          status: DownloadStatus.failed,
          error: 'no download source (empty registry ref and URL)',
        ),
      );
      return;
    }

    final _DownloadSpec spec = _DownloadSpec(entry, url, expectedSha);
    _specs[entry.id] = spec;
    _upsertRow(
      DownloadProgress(
        modelId: entry.id,
        modelName: entry.name,
        receivedBytes: 0,
        totalBytes: totalBytes,
        status: DownloadStatus.queued,
      ),
    );
    _kick(spec, resume: false);
  }

  void _kick(_DownloadSpec spec, {required bool resume}) {
    final Future<void> guarded = _guard(spec, resume: resume);
    _inFlight[spec.entry.id] = guarded;
  }

  Future<void> _guard(_DownloadSpec spec, {required bool resume}) async {
    final String modelId = spec.entry.id;
    try {
      await _transfer(spec, resume: resume);
    } catch (error) {
      // Unexpected IO/programming error: degrade to a failed row but
      // KEEP the .part bytes — a resume may still salvage them.
      try {
        _setRow(
          modelId,
          status: DownloadStatus.failed,
          error: 'download error: $error',
        );
      } catch (_) {
        // The provider was disposed mid-transfer: nothing to report.
      }
    } finally {
      _inFlight.remove(modelId);
    }
  }

  /// Streams one transfer into the `.part` file. [resume] sends a
  /// `Range` request from the current `.part` length when one exists.
  Future<void> _transfer(_DownloadSpec spec, {required bool resume}) async {
    final String modelId = spec.entry.id;
    final Directory dir = await _resolveModelsDir();
    try {
      await dir.create(recursive: true);
    } catch (error) {
      _setRow(
        modelId,
        status: DownloadStatus.failed,
        error: 'cannot create models dir: $error',
      );
      return;
    }
    final File partFile = File(
      '${dir.path}${Platform.pathSeparator}${spec.entry.fileName}.part',
    );

    // A fresh (non-resume) transfer clears stale intents; a resume
    // honors a cancel that landed while it was being scheduled.
    final _Signal? early = _signals.remove(modelId);
    if (!resume) {
      await _tryDelete(partFile); // stale leftovers from an older row
    } else if (early == _Signal.canceled) {
      await _tryDelete(partFile);
      return;
    } else if (early == _Signal.paused) {
      _setRow(modelId, status: DownloadStatus.paused);
      return;
    }

    int offset = 0;
    if (resume && await partFile.exists()) offset = await partFile.length();

    final http.Request request = http.Request('GET', Uri.parse(spec.url))
      ..followRedirects = true;
    if (resume && offset > 0) request.headers['Range'] = 'bytes=$offset-';

    final http.StreamedResponse response;
    try {
      response = await _client().send(request).timeout(connectTimeout);
    } on TimeoutException {
      _setRow(
        modelId,
        status: DownloadStatus.failed,
        error: 'connection timed out',
      );
      return;
    } catch (error) {
      _setRow(modelId, status: DownloadStatus.failed, error: '$error');
      return;
    }

    final int status = response.statusCode;
    if (resume && offset > 0 && status == 200) {
      // Server ignored the Range header: restart the whole file.
      await _tryDelete(partFile);
      offset = 0;
    }

    _Sha256Sink? hasher = spec.expectedSha.isEmpty ? null : _Sha256Sink();
    int received = offset;

    if (status == 416 && resume && offset > 0) {
      // Range unsatisfiable — the .part already covers the blob (pause
      // raced the last chunk). Verify what is on disk and finalize.
      if (hasher != null) {
        try {
          await _hashPrefix(partFile, offset, hasher);
        } catch (error) {
          _setRow(modelId, status: DownloadStatus.failed, error: '$error');
          return;
        }
      }
      await _finalize(modelId, spec, partFile, offset, hasher);
      return;
    }

    if (status != 200 && status != 206) {
      _setRow(modelId, status: DownloadStatus.failed, error: 'HTTP $status');
      return;
    }
    if (status == 206 && offset == 0) {
      _setRow(
        modelId,
        status: DownloadStatus.failed,
        error: 'unexpected HTTP 206 without a range request',
      );
      return;
    }

    // Resuming with 206: the digest must cover the whole file, so the
    // prefix already on disk is hashed before the new chunks arrive.
    if (offset > 0 && hasher != null) {
      try {
        await _hashPrefix(partFile, offset, hasher);
      } catch (error) {
        _setRow(modelId, status: DownloadStatus.failed, error: '$error');
        return;
      }
    }

    final RandomAccessFile file;
    try {
      file = await partFile.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
    } catch (error) {
      _setRow(
        modelId,
        status: DownloadStatus.failed,
        error: 'cannot open part file: $error',
      );
      return;
    }

    _Signal? signal;
    try {
      _setRow(
        modelId,
        status: DownloadStatus.running,
        receivedBytes: received,
        error: '',
      );
      final int? contentLength = response.contentLength;
      await for (final List<int> chunk in response.stream) {
        final _Signal? pending = _signals.remove(modelId);
        if (pending != null) {
          signal = pending;
          break; // breaks the await-for → cancels the HTTP request
        }
        await file.writeFrom(chunk);
        hasher?.add(chunk);
        received += chunk.length;
        _setRow(
          modelId,
          receivedBytes: received,
          totalBytes: contentLength == null ? null : offset + contentLength,
        );
      }
    } finally {
      try {
        await file.close();
      } catch (_) {
        // Already closed or the part was deleted under us.
      }
    }

    if (signal == _Signal.canceled) {
      await _tryDelete(partFile);
      _specs.remove(modelId);
      return;
    }
    if (signal == _Signal.paused) {
      _setRow(modelId, status: DownloadStatus.paused, receivedBytes: received);
      return;
    }

    await _finalize(modelId, spec, partFile, received, hasher);
  }

  /// Feeds the first [length] bytes of [partFile] into [hasher] (the
  /// resume prefix of the digest).
  Future<void> _hashPrefix(
    File partFile,
    int length,
    _Sha256Sink hasher,
  ) async {
    final RandomAccessFile reader = await partFile.open();
    try {
      await reader.setPosition(0);
      int remaining = length;
      while (remaining > 0) {
        final List<int> chunk = await reader.read(
          remaining < 64 * 1024 ? remaining : 64 * 1024,
        );
        if (chunk.isEmpty) break;
        hasher.add(chunk);
        remaining -= chunk.length;
      }
    } finally {
      await reader.close();
    }
  }

  /// Verifies the digest (when known), renames `.part` → final file
  /// name and reports the row + completion hook. A mismatch DELETES the
  /// `.part` (a corrupt file must never be resumable — every appended
  /// byte would stay wrong).
  Future<void> _finalize(
    String modelId,
    _DownloadSpec spec,
    File partFile,
    int received,
    _Sha256Sink? hasher,
  ) async {
    final String actual = hasher?.close() ?? '';
    if (spec.expectedSha.isNotEmpty && actual != spec.expectedSha) {
      await _tryDelete(partFile);
      _setRow(
        modelId,
        status: DownloadStatus.failed,
        error: 'sha256 mismatch (expected ${spec.expectedSha}, got $actual)',
      );
      _specs.remove(modelId);
      return;
    }
    final File target = File(
      '${partFile.parent.path}${Platform.pathSeparator}${spec.entry.fileName}',
    );
    try {
      await partFile.rename(target.path);
    } catch (error) {
      // cancel() may have deleted the .part between the last chunk and
      // the rename — never resurrect a canceled row as failed.
      final DownloadProgress? row = _rowOf(modelId);
      if (row != null && row.status == DownloadStatus.canceled) {
        _specs.remove(modelId);
        return;
      }
      _setRow(
        modelId,
        status: DownloadStatus.failed,
        error: 'cannot finalize download: $error',
      );
      _specs.remove(modelId);
      return;
    }
    _setRow(
      modelId,
      status: DownloadStatus.completed,
      receivedBytes: received,
      totalBytes: received,
      error: '',
    );
    _specs.remove(modelId);
    await _notifyCompleted(
      spec.entry.copyWith(
        sizeBytes: received,
        sha256: actual.isEmpty ? spec.entry.sha256 : actual,
      ),
    );
  }

  /// Pauses the transfer of [modelId]: the row flips to paused
  /// immediately; the in-flight request closes as soon as the loop
  /// observes the intent (next chunk). The `.part` file is kept.
  Future<void> pause(String modelId) async {
    final DownloadProgress? row = _rowOf(modelId);
    if (row == null) return;
    if (row.status != DownloadStatus.queued &&
        row.status != DownloadStatus.running) {
      return;
    }
    _signals[modelId] = _Signal.paused;
    _setRow(modelId, status: DownloadStatus.paused);
  }

  /// Resumes the paused row of [modelId]: awaits the old transfer's
  /// wind-down, then restarts with a `Range` request from the current
  /// `.part` length (206 appends; a 200 restarts the file).
  Future<void> resume(String modelId) async {
    DownloadProgress? row = _rowOf(modelId);
    if (row == null) return;
    if (row.status != DownloadStatus.paused) return;
    final _DownloadSpec? spec = _specs[modelId];
    if (spec == null) {
      _setRow(
        modelId,
        status: DownloadStatus.failed,
        error: 'download is no longer resumable',
      );
      return;
    }
    final Future<void>? inFlight = _inFlight[modelId];
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {
        // The guard never rethrows; defensive only.
      }
    }
    row = _rowOf(modelId);
    if (row == null || row.status != DownloadStatus.paused) {
      return; // canceled/failed while winding down
    }
    _signals.remove(modelId);
    _setRow(modelId, status: DownloadStatus.queued);
    _kick(spec, resume: true);
  }

  /// Cancels the row of [modelId] and deletes its `.part` file. A
  /// canceled row stays visible (with the bytes already gone) until
  /// [clearFinished].
  Future<void> cancel(String modelId) async {
    final DownloadProgress? row = _rowOf(modelId);
    if (row == null) return;
    if (row.status == DownloadStatus.completed ||
        row.status == DownloadStatus.canceled) {
      return;
    }
    final _DownloadSpec? spec = _specs[modelId];
    final String fileName = spec?.entry.fileName ?? '$modelId.gguf';
    _signals[modelId] = _Signal.canceled;
    _setRow(modelId, status: DownloadStatus.canceled, error: '');
    _specs.remove(modelId);
    // Best-effort immediate cleanup; an in-flight writer holds the old
    // (unlinked) inode until it winds down and swallows the rename.
    final Directory dir = await _resolveModelsDir();
    await _tryDelete(
      File('${dir.path}${Platform.pathSeparator}$fileName.part'),
    );
  }

  /// Drops completed/failed/canceled rows from the visible list.
  void clearFinished() {
    final List<DownloadProgress> kept = <DownloadProgress>[];
    for (final DownloadProgress row in state) {
      final bool finished =
          row.status == DownloadStatus.completed ||
          row.status == DownloadStatus.failed ||
          row.status == DownloadStatus.canceled;
      if (finished) {
        _specs.remove(row.modelId);
      } else {
        kept.add(row);
      }
    }
    state = kept;
  }

  /// Absolute path of the models dir (created when missing) — shared
  /// root of the downloader, the importer and the store.
  Future<String> modelsDirPath() async {
    final Directory dir = await _resolveModelsDir();
    try {
      await dir.create(recursive: true);
    } catch (_) {
      // Read-only storage: the path is still reported (the caller
      // decides how to surface the failure).
    }
    return dir.path;
  }
}
