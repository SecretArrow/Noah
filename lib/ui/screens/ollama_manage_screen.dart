import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/local_model.dart';
import '../../models/models.dart' show AppSettings, ProviderPreset;
import '../../services/local_ai/llm_benchmark.dart';
import '../../services/local_ai/llm_server_controller.dart'
    show LlmServerState, LlmServerStatus;
import '../../services/local_ai/model_catalog_data.dart'
    show
        CatalogModelEntry,
        CatalogTier,
        kLocalAiCatalog,
        catalogModelFits,
        mergeCatalog;
import '../../services/local_ai/model_downloader.dart'
    show DownloadProgress, DownloadStatus;
import '../../services/local_ai/remote_catalog.dart'
    show RemoteCatalogException, kRemoteCatalogUrl;
import '../theme.dart';
import '../widgets/app_message.dart';

/// Name of the built-in provider preset that targets the local llama-server
/// (see [providerPresets] in models.dart). "Use in chat" writes the running
/// model's alias into this preset and activates it.
const String _kLocalAiPresetName = 'Local AI';

const Uuid _uuid = Uuid();

const Color _kAmber = Color(0xFFE8A33D);
const Color _kGreen = Color(0xFF2E9E5B);
const Color _kRed = Color(0xFFD0453E);
const Color _kGrey = Color(0xFF9AA0B4);

/// Full-screen manager for the on-device LLM runtime (v1.51.0, extended in
/// v1.52.0): a bundled llama-server that speaks the Ollama-compatible
/// OpenAI API on 127.0.0.1.
///
/// Four tabs behind an explicit [TabController] (v1.52.0 — the screen owns
/// the controller so the AppBar reacts to tab changes for the bulk-export
/// selection mode, which auto-exits whenever the user leaves Installed):
/// * **Server** — status card (+ benchmark result line), battery/device-RAM
///   diagnostics, model picker, Start/Stop, port/context/threads config,
///   log tail + full-screen log viewer, external-Ollama probe row,
/// * **Catalog** — curated registry models (RAM auto-filter + remote
///   catalog refresh/reset) + custom .gguf URL + file import,
/// * **Installed** — local models with start/export/delete actions and a
///   bulk-export selection mode,
/// * **Downloads** — live progress rows with pause/resume/cancel.
///
/// The server tab polls every 3 s ([Timer.periodic] cancelled in dispose),
/// calling `pollNow` + `refresh` on the server controller so the status
/// card and log tail stay live without the user pulling anything.
class OllamaManageScreen extends ConsumerStatefulWidget {
  const OllamaManageScreen({super.key});

  @override
  ConsumerState<OllamaManageScreen> createState() => _OllamaManageScreenState();
}

class _OllamaManageScreenState extends ConsumerState<OllamaManageScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final TextEditingController _port;
  late final TextEditingController _contextSize;
  late final TextEditingController _threads;
  late final TextEditingController _externalHost;
  late final TextEditingController _customUrl;

  /// Selected installed-model id for the Server tab dropdown (null = the
  /// first installed model is offered). Only ever changed by user picks or
  /// "start with this model" from the Installed tab.
  String? _selectedModelId;

  /// True while an external-server probe is in flight (disables the button).
  bool _probing = false;

  /// Last battery sample from the platform (-1 = unknown → line hidden).
  int _batteryPercent = -1;
  bool _batteryCharging = false;

  /// v1.52.0 — “Only models that fit” toggle (default ON; only meaningful
  /// once device RAM is known).
  bool _fitFilter = true;

  /// v1.52.0 — true while a remote-catalog fetch is in flight.
  bool _catalogRefreshing = false;

  /// v1.52.0 — bulk-export selection mode on the Installed tab. Left in
  /// the tab index by [_onTabChanged] so leaving the tab always exits it.
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  int _lastTabIndex = 0;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _tabs.addListener(_onTabChanged);
    final LocalModelState config = ref.read(localModelsProvider);
    _port = TextEditingController(text: '${config.serverPort}');
    _contextSize = TextEditingController(text: '${config.contextSize}');
    _threads = TextEditingController(text: '${config.threads}');
    _externalHost = TextEditingController(text: '127.0.0.1:11434');
    _customUrl = TextEditingController();
    // Coherent first paint: runtime availability + current run state.
    _refreshServerState();
    _pollDeviceStats();
    // Live status + log tail while the screen is open. The fake-async
    // widget-test zone never advances the clock past one settle, so the
    // periodic callback does not fire there; dispose always cancels it.
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      _refreshServerState();
      _pollDeviceStats();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _port.dispose();
    _contextSize.dispose();
    _threads.dispose();
    _externalHost.dispose();
    _customUrl.dispose();
    super.dispose();
  }

  /// Keeps the AppBar coherent with the active tab (the checklist toggle
  /// only exists on Installed) and exits selection mode whenever the user
  /// leaves the Installed tab.
  void _onTabChanged() {
    final int index = _tabs.index;
    if (index == _lastTabIndex) return;
    _lastTabIndex = index;
    if (_selectionMode && index != 2) {
      _selectionMode = false;
      _selectedIds.clear();
    }
    setState(() {});
  }

  /// v1.52.0 — runs one tokens/s benchmark against the running server and
  /// stores the outcome in [benchmarkRunProvider] (screen state, NOT the
  /// frozen LlmServerState).
  Future<void> _runBenchmark() async {
    final LlmServerState server = ref.read(llmServerProvider);
    if (server.status != LlmServerStatus.running) return;
    ref.read(benchmarkRunProvider.notifier).state = const BenchmarkRunState(
      status: BenchmarkRunStatus.running,
    );
    try {
      final LlmBenchmarkResult result =
          await LlmBenchmark(client: ref.read(llmHttpClientProvider)).run(
            baseUrl: 'http://127.0.0.1:${server.port}',
            model: server.activeModelName,
          );
      ref.read(benchmarkRunProvider.notifier).state = BenchmarkRunState(
        status: BenchmarkRunStatus.done,
        result: result,
      );
    } on LlmBenchmarkException catch (error) {
      ref.read(benchmarkRunProvider.notifier).state = BenchmarkRunState(
        status: BenchmarkRunStatus.failed,
        message: error.message,
      );
    } catch (error) {
      ref.read(benchmarkRunProvider.notifier).state = BenchmarkRunState(
        status: BenchmarkRunStatus.failed,
        message: '$error',
      );
    }
  }

  /// v1.52.0 — full-screen log viewer (monospace, auto-scrolled to the
  /// bottom, Copy-all + Close).
  Future<void> _openLogViewer() async {
    final List<String> lines = ref.read(llmServerProvider).logTail;
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext context) => _LogViewerScreen(lines: lines),
      ),
    );
  }

  /// v1.52.0 — fetches the remote catalog, persists it as the overlay and
  /// reports the count (or the failure) through the feedback surface.
  Future<void> _refreshCatalog() async {
    if (_catalogRefreshing) return;
    final AppStrings strings = _strings;
    setState(() => _catalogRefreshing = true);
    try {
      final List<CatalogModelEntry> entries = await ref
          .read(remoteCatalogProvider)
          .fetch(kRemoteCatalogUrl);
      await ref.read(localModelsProvider.notifier).setRemoteCatalog(entries);
      if (!mounted) return;
      showAppMessage(context, strings.ollamaCatalogRefreshDone(entries.length));
    } on RemoteCatalogException catch (error) {
      if (!mounted) return;
      showAppMessage(
        context,
        strings.ollamaCatalogRefreshFailed(error.message),
        error: true,
      );
    } catch (error) {
      if (!mounted) return;
      showAppMessage(
        context,
        strings.ollamaCatalogRefreshFailed('$error'),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _catalogRefreshing = false);
    }
  }

  /// v1.52.0 — clears the overlay (back to the built-ins).
  Future<void> _resetCatalog() async {
    final AppStrings strings = _strings;
    await ref
        .read(localModelsProvider.notifier)
        .setRemoteCatalog(const <CatalogModelEntry>[]);
    if (!mounted) return;
    showAppMessage(context, strings.ollamaCatalogResetDone);
  }

  // -- Bulk export (v1.52.0) --------------------------------------------------

  void _enterSelection() {
    setState(() => _selectionMode = true);
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(String id, bool? checked) {
    setState(() {
      if (checked ?? false) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  /// Stages every checked model through LocalModelIo.exportModels (one
  /// share sheet) and reports the outcome; exits selection mode after.
  Future<void> _exportSelected() async {
    if (_selectedIds.isEmpty) return;
    final AppStrings strings = _strings;
    final List<LocalModelEntry> selected = <LocalModelEntry>[];
    for (final LocalModelEntry entry
        in ref.read(localModelsProvider).installed) {
      if (_selectedIds.contains(entry.id)) selected.add(entry);
    }
    final int count = await ref
        .read(localModelIoProvider)
        .exportModels(selected);
    if (!mounted) return;
    _exitSelection();
    showAppMessage(
      context,
      count > 0
          ? strings.ollamaExportSelectedDone(count)
          : strings.ollamaExportNone,
      error: count == 0,
    );
  }

  /// v1.51.0 — coherent server status: refresh (runtime availability +
  /// latched run state) then pollNow (one /health probe) on the server
  /// controller. Re-added in v1.52.0 after the TabController refactor
  /// accidentally dropped the definition while keeping the call sites.
  void _refreshServerState() {
    // Inferred on purpose: the screen imports the provider (di.dart), not
    // the controller class by name.
    final controller = ref.read(llmServerProvider.notifier);
    controller.refresh();
    controller.pollNow();
  }

  /// v1.52.0 — battery + device-RAM poll (same 3 s cadence as the server
  /// poll). RAM is stable per boot, so it is cached once into
  /// [deviceRamBytesProvider] and never re-read; the battery flips between
  /// charging/discharging, so it is re-read every tick.
  Future<void> _pollDeviceStats() async {
    final platform = ref.read(llmServerPlatformProvider);
    int percent = _batteryPercent;
    bool charging = _batteryCharging;
    try {
      final Map<String, dynamic> battery = await platform.batteryStatus();
      percent = (battery['percent'] as num?)?.toInt() ?? -1;
      charging = battery['charging'] == true;
    } catch (_) {
      // Defensive platform contract: keep the last sample.
    }
    int? ram = ref.read(deviceRamBytesProvider);
    if (ram == null) {
      try {
        final int probed = await platform.deviceTotalRamBytes();
        if (probed > 0) {
          ram = probed;
          ref.read(deviceRamBytesProvider.notifier).state = probed;
        }
      } catch (_) {
        // Unknown RAM stays unknown — the RAM line/filter stay hidden.
      }
    }
    if (!mounted) return;
    if (percent != _batteryPercent || charging != _batteryCharging) {
      setState(() {
        _batteryPercent = percent;
        _batteryCharging = charging;
      });
    }
  }

  AppStrings get _strings => stringsOf(context);

  // -- Actions ---------------------------------------------------------------

  /// Starts the server with [entry] as the active model: marks it used,
  /// resolves the models dir, then launches with the stored port/context/
  /// threads config (threads 0 = auto, resolved by the native side).
  Future<void> _startModel(LocalModelEntry entry) async {
    final AppStrings strings = _strings;
    final LocalModelState config = ref.read(localModelsProvider);
    ref.read(localModelsProvider.notifier).markUsed(entry.id);
    final String modelPath;
    try {
      // Models live at `<modelsDir>/<fileName>` — on Android the separator
      // is always '/', matching the downloader's own path building.
      final String dir = await ref
          .read(downloadQueueProvider.notifier)
          .modelsDirPath();
      modelPath = '$dir/${entry.fileName}';
    } catch (_) {
      if (mounted) {
        showAppMessage(context, strings.ollamaStartFailedSnack, error: true);
      }
      return;
    }
    final bool ok = await ref
        .read(llmServerProvider.notifier)
        .start(
          modelPath: modelPath,
          modelName: entry.name,
          port: config.serverPort,
          contextSize: config.contextSize,
          threads: config.threads,
        );
    if (!mounted) return;
    if (ok) {
      showAppMessage(context, strings.ollamaStartedSnack);
    } else {
      final LlmServerState state = ref.read(llmServerProvider);
      showAppMessage(
        context,
        state.message.isNotEmpty
            ? state.message
            : strings.ollamaStartFailedSnack,
        error: true,
      );
    }
  }

  Future<void> _stopServer() async {
    final AppStrings strings = _strings;
    final bool ok = await ref.read(llmServerProvider.notifier).stop();
    if (!mounted) return;
    if (ok) {
      showAppMessage(context, strings.ollamaStoppedSnack);
    } else {
      final LlmServerState state = ref.read(llmServerProvider);
      showAppMessage(
        context,
        state.message.isNotEmpty ? state.message : strings.operationFailed,
        error: true,
      );
    }
  }

  /// Persists the port / context / threads fields (validated against the
  /// 1024–65535 / 512–32768 / 0–8 ranges from the feature contract).
  void _saveConfig() {
    final AppStrings strings = _strings;
    final int? port = int.tryParse(_port.text.trim());
    final int? contextSize = int.tryParse(_contextSize.text.trim());
    final int? threads = int.tryParse(_threads.text.trim());
    final bool valid =
        port != null &&
        port >= 1024 &&
        port <= 65535 &&
        contextSize != null &&
        contextSize >= 512 &&
        contextSize <= 32768 &&
        threads != null &&
        threads >= 0 &&
        threads <= 8;
    if (!valid) {
      showAppMessage(context, strings.ollamaConfigInvalid, error: true);
      return;
    }
    ref
        .read(localModelsProvider.notifier)
        .setServerConfig(
          port: port,
          contextSize: contextSize,
          threads: threads,
        );
    showAppMessage(context, strings.ollamaConfigSaved);
  }

  /// "Use in chat" (running server only): writes the active model alias
  /// into the built-in `Local AI` preset and activates it — the same
  /// upsert+activate combination PresetEditorScreen._upsert and the
  /// providers screen activation use, so the very next message runs
  /// against the local server.
  Future<void> _useInChat() async {
    final AppStrings strings = _strings;
    final LlmServerState server = ref.read(llmServerProvider);
    final String alias = server.activeModelName;
    if (alias.isEmpty) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('ollama-use-dialog'),
        title: Text(strings.ollamaUseInChatTitle),
        content: Text(strings.ollamaUseInChatBody(alias)),
        actions: <Widget>[
          TextButton(
            key: const Key('ollama-use-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('ollama-use-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.ollamaUseInChat),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final AppSettings settings = ref.read(settingsProvider);
    ProviderPreset? localAi;
    for (final ProviderPreset p in settings.presets) {
      if (p.name == _kLocalAiPresetName) {
        localAi = p;
        break;
      }
    }
    if (localAi == null) {
      showAppMessage(context, strings.operationFailed, error: true);
      return;
    }
    final ProviderPreset updated = localAi.copyWith(model: alias);
    await ref
        .read(settingsProvider.notifier)
        .update(
          settings.copyWith(
            providerName: updated.name,
            baseUrl: updated.baseUrl,
            apiKey: updated.apiKey,
            model: updated.model,
            engine: updated.engine,
            presets: <ProviderPreset>[
              for (final ProviderPreset p in settings.presets)
                if (p.id == updated.id) updated else p,
            ],
          ),
        );
    if (mounted) showAppMessage(context, strings.ollamaUseInChatDone);
  }

  /// Probes the user-entered host for an external Ollama server.
  Future<void> _probeExternal() async {
    if (_probing) return;
    final AppStrings strings = _strings;
    final String host = _externalHost.text.trim();
    if (host.isEmpty) return;
    setState(() => _probing = true);
    final scan = await ref.read(externalOllamaScannerProvider).probe(host);
    if (!mounted) return;
    setState(() => _probing = false);
    showAppMessage(
      context,
      scan.ok
          ? strings.ollamaProbeOk(scan.version)
          : strings.ollamaProbeFail(scan.error ?? ''),
    );
  }

  /// Builds the queue entry for a download and enqueues it. The uuid doubles
  /// as the file stem (`<uuid>.gguf`) inside the models dir, matching the
  /// downloader's on-disk layout.
  void _enqueueDownload({
    required String name,
    required LocalModelSource source,
    String ollamaRef = '',
    String customUrl = '',
  }) {
    final AppStrings strings = _strings;
    final String id = _uuid.v4();
    final LocalModelEntry entry = LocalModelEntry(
      id: id,
      name: name,
      source: source,
      ollamaRef: ollamaRef,
      customUrl: customUrl,
      fileName: '$id.gguf',
      addedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    ref.read(downloadQueueProvider.notifier).enqueue(entry);
    showAppMessage(context, strings.ollamaDownloadStarted(entry.name));
  }

  Future<void> _downloadCatalogEntry(CatalogModelEntry model) async {
    final AppStrings strings = _strings;
    // v1.52.0 — the RAM filter extends the risk-dialog gate: a model that
    // does NOT fit this device confirms through the SAME dialog even when
    // its tier is not upperBound ("Download anyway").
    final int? ram = ref.read(deviceRamBytesProvider);
    final bool ramKnown = ram != null && ram > 0;
    final bool fits = !ramKnown || catalogModelFits(model.ramEstBytes, ram);
    final bool needsDialog =
        model.tier == CatalogTier.upperBound || (ramKnown && !fits);
    if (needsDialog) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          key: const Key('ollama-risk-dialog'),
          title: Text(strings.ollamaRiskTitle),
          content: Text(strings.ollamaRiskBody(model.ollamaRef)),
          actions: <Widget>[
            TextButton(
              key: const Key('ollama-risk-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const Key('ollama-risk-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.ollamaDownload),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    _enqueueDownload(
      name: model.ollamaRef,
      source: LocalModelSource.catalog,
      ollamaRef: model.ollamaRef,
    );
  }

  /// Custom direct .gguf URL download: http(s) scheme + .gguf suffix are
  /// validated; the display name is the last URL path segment minus the
  /// extension.
  void _downloadCustomUrl() {
    final AppStrings strings = _strings;
    final String raw = _customUrl.text.trim();
    final Uri? uri = Uri.tryParse(raw);
    final bool valid =
        uri != null &&
        (uri.isScheme('http') || uri.isScheme('https')) &&
        uri.path.toLowerCase().endsWith('.gguf');
    if (!valid) {
      showAppMessage(context, strings.ollamaCustomUrlInvalid, error: true);
      return;
    }
    String segment = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (segment.toLowerCase().endsWith('.gguf')) {
      segment = segment.substring(0, segment.length - 5);
    }
    _enqueueDownload(
      name: segment.isEmpty ? 'model' : segment,
      source: LocalModelSource.customUrl,
      customUrl: raw,
    );
  }

  /// Imports a .gguf picked with the system file picker, copies it into the
  /// models dir (hashing + size via [LocalModelIo]) and registers it.
  Future<void> _importFromFile() async {
    final AppStrings strings = _strings;
    const XTypeGroup ggufGroup = XTypeGroup(
      label: 'GGUF model',
      extensions: <String>['gguf'],
    );
    final XFile? picked = await openFile(
      acceptedTypeGroups: <XTypeGroup>[ggufGroup],
    );
    if (picked == null) return;
    final LocalModelEntry? entry = await ref
        .read(localModelIoProvider)
        .importFromFile(sourcePath: picked.path, fileNameHint: picked.name);
    if (!mounted) return;
    if (entry == null) {
      showAppMessage(context, strings.ollamaImportFailed, error: true);
      return;
    }
    ref.read(localModelsProvider.notifier).addInstalled(entry);
    showAppMessage(context, strings.ollamaImportDone(entry.name));
  }

  Future<void> _confirmDeleteInstalled(LocalModelEntry entry) async {
    final AppStrings strings = _strings;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('ollama-delete-dialog'),
        title: Text(strings.ollamaDeleteTitle),
        content: Text(strings.ollamaDeleteBody(entry.name)),
        actions: <Widget>[
          TextButton(
            key: const Key('ollama-delete-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('ollama-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      // The controller also removes the backing file.
      ref.read(localModelsProvider.notifier).removeInstalled(entry.id);
    }
  }

  Future<void> _exportModel(LocalModelEntry entry) async {
    final AppStrings strings = _strings;
    final bool ok = await ref.read(localModelIoProvider).exportModel(entry);
    if (!mounted) return;
    showAppMessage(
      context,
      ok ? strings.ollamaExportDone : strings.operationFailed,
      error: !ok,
    );
  }

  // -- Build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = _strings;
    final LocalModelState models = ref.watch(localModelsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectionMode
              ? strings.ollamaSelectedCount(_selectedIds.length)
              : strings.ollamaScreenTitle,
        ),
        actions: _appBarActions(strings, models),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: false,
          tabs: <Widget>[
            Tab(
              key: const Key('ollama-tab-server'),
              icon: const Icon(Icons.dns_outlined, size: 18),
              text: strings.ollamaTabServer,
            ),
            Tab(
              key: const Key('ollama-tab-catalog'),
              icon: const Icon(Icons.shopping_bag_outlined, size: 18),
              text: strings.ollamaTabCatalog,
            ),
            Tab(
              key: const Key('ollama-tab-installed'),
              icon: const Icon(Icons.inventory_2_outlined, size: 18),
              text: strings.ollamaTabInstalled,
            ),
            Tab(
              key: const Key('ollama-tab-downloads'),
              icon: const Icon(Icons.download_outlined, size: 18),
              text: strings.ollamaTabDownloads,
            ),
          ],
        ),
      ),
      // top:false: the AppBar already reserves the status bar height;
      // bottom keeps the last cards above the system navigation bar.
      body: SafeArea(
        top: false,
        child: TabBarView(
          controller: _tabs,
          children: <Widget>[
            Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  _serverTab(context, ref),
            ),
            Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  _catalogTab(context, ref),
            ),
            Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  _installedTab(context, ref),
            ),
            Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  _downloadsTab(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  /// AppBar actions: selection mode (count title + Export selected +
  /// exit) vs. the checklist toggle while the Installed tab is showing a
  /// non-empty list.
  List<Widget> _appBarActions(AppStrings strings, LocalModelState models) {
    if (_selectionMode) {
      return <Widget>[
        TextButton.icon(
          key: const Key('ollama-export-selected'),
          onPressed: _selectedIds.isEmpty ? null : _exportSelected,
          icon: const Icon(Icons.ios_share_rounded, size: 18),
          label: Text(strings.ollamaExportSelected),
        ),
        IconButton(
          key: const Key('ollama-exit-selection'),
          tooltip: strings.cancel,
          icon: const Icon(Icons.close_rounded),
          onPressed: _exitSelection,
        ),
      ];
    }
    if (_tabs.index == 2 && models.installed.isNotEmpty) {
      return <Widget>[
        IconButton(
          key: const Key('ollama-select-mode'),
          tooltip: strings.ollamaSelectMode,
          icon: const Icon(Icons.checklist),
          onPressed: _enterSelection,
        ),
      ];
    }
    return const <Widget>[];
  }

  // -- Server tab --------------------------------------------------------------

  Widget _serverTab(BuildContext context, WidgetRef ref) {
    final AppStrings strings = _strings;
    final ZPalette palette = context.palette;
    final LlmServerState server = ref.watch(llmServerProvider);
    final LocalModelState models = ref.watch(localModelsProvider);
    final BenchmarkRunState bench = ref.watch(benchmarkRunProvider);
    final bool benchRunning = bench.status == BenchmarkRunStatus.running;
    final bool running = server.status == LlmServerStatus.running;
    final bool busy =
        server.status == LlmServerStatus.starting ||
        server.status == LlmServerStatus.stopping;
    final LocalModelEntry? selected = _selectedEntry(models.installed);
    return ListView(
      key: const Key('ollama-server-list'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        if (server.status == LlmServerStatus.unavailable)
          _unavailableBanner(strings),
        if (server.status == LlmServerStatus.unavailable)
          const SizedBox(height: 8),
        _statusCard(strings, palette, server, bench),
        const SizedBox(height: 8),
        _deviceLines(strings, palette),
        const SizedBox(height: 12),

        // -- Model picker -----------------------------------------------
        if (models.installed.isEmpty)
          Card(
            key: const Key('ollama-model-empty'),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: <Widget>[
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 32,
                    color: palette.muted,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.ollamaModelEmptyHint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.muted,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('ollama-go-catalog'),
                    icon: const Icon(Icons.shopping_bag_outlined, size: 18),
                    label: Text(strings.ollamaGoToCatalog),
                    onPressed: () => _tabs.animateTo(1),
                  ),
                ],
              ),
            ),
          )
        else
          // The key changes with the installed set and the selection so a
          // rebuilt DropdownButtonFormField re-seeds its initialValue
          // (fresh FormFieldState) — programmatic selection changes and
          // deletions of the selected model both stay coherent.
          DropdownButtonFormField<String>(
            key: ValueKey<String>(
              'ollama-model-dropdown-'
              '${models.installed.map((LocalModelEntry e) => e.id).join('|')}'
              '-${selected?.id}',
            ),
            initialValue: selected?.id,
            isExpanded: true,
            decoration: InputDecoration(labelText: strings.ollamaModelLabel),
            items: <DropdownMenuItem<String>>[
              for (final LocalModelEntry e in models.installed)
                DropdownMenuItem<String>(
                  value: e.id,
                  child: Text(e.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (String? value) =>
                setState(() => _selectedModelId = value),
          ),
        const SizedBox(height: 12),

        // -- Start / Stop -----------------------------------------------
        if (running || server.status == LlmServerStatus.stopping)
          FilledButton.icon(
            key: const Key('ollama-stop'),
            style: FilledButton.styleFrom(
              backgroundColor: _kRed.withValues(alpha: 0.85),
            ),
            onPressed: server.status == LlmServerStatus.stopping
                ? null
                : _stopServer,
            icon: const Icon(Icons.stop_rounded),
            label: Text(strings.ollamaStop),
          )
        else
          FilledButton.icon(
            key: const Key('ollama-start'),
            onPressed:
                selected == null ||
                    busy ||
                    server.status == LlmServerStatus.unavailable
                ? null
                : () => _startModel(selected),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(strings.ollamaStart),
          ),
        if (running) ...<Widget>[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('ollama-use-in-chat'),
            icon: const Icon(Icons.forum_rounded, size: 18),
            label: Text(strings.ollamaUseInChat),
            onPressed: _useInChat,
          ),
          const SizedBox(height: 8),
          // v1.52.0 — tokens/s benchmark (only while serving).
          OutlinedButton.icon(
            key: const Key('ollama-benchmark'),
            onPressed: benchRunning ? null : _runBenchmark,
            icon: const Icon(Icons.speed, size: 18),
            label: Text(
              benchRunning
                  ? strings.ollamaBenchmarkRunning
                  : strings.ollamaBenchmark,
            ),
          ),
        ],
        const SizedBox(height: 16),

        // -- Config -------------------------------------------------------
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const Key('ollama-port-field'),
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: strings.ollamaPortLabel),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const Key('ollama-context-field'),
                controller: _contextSize,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: strings.ollamaContextLabel,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const Key('ollama-threads-field'),
                controller: _threads,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: strings.ollamaThreadsLabel,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('ollama-config-save'),
          icon: const Icon(Icons.save_outlined, size: 18),
          label: Text(strings.ollamaConfigSave),
          onPressed: _saveConfig,
        ),
        const SizedBox(height: 16),

        // -- Log tail -------------------------------------------------------
        if (server.logTail.isNotEmpty) ...<Widget>[
          Text(
            strings.ollamaLogTitle,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Container(
            key: const Key('ollama-log-tail'),
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.zSurfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.zBorder),
            ),
            child: Text(
              server.logTail.join('\n'),
              maxLines: 12,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 4),
          // v1.52.0 — full-screen log viewer.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('ollama-log-viewer'),
              onPressed: _openLogViewer,
              icon: const Icon(Icons.article, size: 18),
              label: Text(strings.ollamaViewFullLog),
            ),
          ),
          const SizedBox(height: 16),
        ],

        // -- External Ollama server ------------------------------------------
        Text(
          strings.ollamaExternalServerLabel,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const Key('ollama-external-host'),
                controller: _externalHost,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(hintText: '127.0.0.1:11434'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('ollama-probe'),
              onPressed: _probing ? null : _probeExternal,
              child: Text(strings.ollamaProbe),
            ),
          ],
        ),
      ],
    );
  }

  LocalModelEntry? _selectedEntry(List<LocalModelEntry> installed) {
    for (final LocalModelEntry e in installed) {
      if (e.id == _selectedModelId) return e;
    }
    // Nothing picked yet: offer the first installed model.
    return installed.isEmpty ? null : installed.first;
  }

  Widget _unavailableBanner(AppStrings strings) => Container(
    key: const Key('ollama-unavailable-banner'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: _kAmber.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _kAmber.withValues(alpha: 0.6)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(Icons.warning_amber_rounded, size: 18, color: _kAmber),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            strings.ollamaRuntimeUnavailable,
            style: const TextStyle(fontSize: 11.5, height: 1.35),
          ),
        ),
      ],
    ),
  );

  /// v1.52.0 — battery + device-RAM diagnostics under the status card.
  /// Both lines hide while unknown (battery -1 / RAM unprobed).
  Widget _deviceLines(AppStrings strings, ZPalette palette) {
    final int? ram = ref.watch(deviceRamBytesProvider);
    final bool ramKnown = ram != null && ram > 0;
    final bool batteryKnown = _batteryPercent >= 0;
    if (!batteryKnown && !ramKnown) return const SizedBox.shrink();
    final bool low =
        _batteryPercent >= 0 && _batteryPercent < 20 && !_batteryCharging;
    return Column(
      key: const Key('ollama-device-lines'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (batteryKnown)
          Row(
            key: const Key('ollama-battery'),
            children: <Widget>[
              Icon(
                _batteryCharging
                    ? Icons.battery_charging_full
                    : low
                    ? Icons.battery_alert
                    : Icons.battery_std,
                size: 14,
                color: low ? _kRed : palette.muted,
              ),
              const SizedBox(width: 6),
              Text(
                _batteryCharging
                    ? strings.ollamaBatteryCharging(_batteryPercent)
                    : low
                    ? strings.ollamaBatteryLow(_batteryPercent)
                    : strings.ollamaBattery(_batteryPercent),
                style: TextStyle(
                  fontSize: 11.5,
                  color: low ? _kRed : palette.muted,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        if (batteryKnown && ramKnown) const SizedBox(height: 4),
        if (ramKnown)
          Row(
            key: const Key('ollama-ram-line'),
            children: <Widget>[
              Icon(Icons.memory, size: 14, color: palette.muted),
              const SizedBox(width: 6),
              Text(
                strings.ollamaDeviceRam(_fmtBytes(ram)),
                style: TextStyle(
                  fontSize: 11.5,
                  color: palette.muted,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _statusCard(
    AppStrings strings,
    ZPalette palette,
    LlmServerState server,
    BenchmarkRunState bench,
  ) => Card(
    key: const Key('ollama-status-card'),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _serverStatusColor(server.status),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _serverStatusLabel(strings, server.status),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (server.port > 0) ...<Widget>[
                const SizedBox(width: 10),
                Text(
                  '${strings.ollamaPortLabel} ${server.port}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.muted,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (server.activeModelName.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              '${strings.ollamaActiveModelLabel}: ${server.activeModelName}',
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ],
          if (server.status == LlmServerStatus.failed &&
              server.message.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              server.message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: _kRed),
            ),
          ],
          // v1.52.0 — last benchmark outcome (result line / failure text).
          if (bench.status == BenchmarkRunStatus.done &&
              bench.result != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              strings.ollamaBenchmarkSummary(
                bench.result!.tokensPerSecond.toStringAsFixed(1),
                bench.result!.firstTokenLatency.inMilliseconds,
                bench.result!.totalTokens,
              ),
              key: const Key('ollama-benchmark-result'),
              style: TextStyle(
                fontSize: 11.5,
                color: _kGreen,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ] else if (bench.status == BenchmarkRunStatus.failed &&
              bench.message.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              bench.message,
              key: const Key('ollama-benchmark-result'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: _kRed),
            ),
          ],
        ],
      ),
    ),
  );

  // -- Catalog tab ---------------------------------------------------------------

  Widget _catalogTab(BuildContext context, WidgetRef ref) {
    final AppStrings strings = _strings;
    final LocalModelState models = ref.watch(localModelsProvider);
    final List<DownloadProgress> downloads = ref.watch(downloadQueueProvider);
    final int? ram = ref.watch(deviceRamBytesProvider);
    final bool ramKnown = ram != null && ram > 0;
    final Set<String> installedRefs = <String>{
      for (final LocalModelEntry e in models.installed)
        if (e.ollamaRef.isNotEmpty) e.ollamaRef,
    };
    final Set<String> activeNames = <String>{
      for (final DownloadProgress d in downloads)
        if (d.status == DownloadStatus.queued ||
            d.status == DownloadStatus.running ||
            d.status == DownloadStatus.paused)
          d.modelName,
    };
    // v1.52.0 — built-ins overlaid with the fetched remote catalog.
    final List<CatalogModelEntry> merged = mergeCatalog(
      kLocalAiCatalog,
      models.remoteCatalog,
    );
    // v1.52.0 — the fit filter hides non-fitting cards (default ON).
    final Iterable<CatalogModelEntry> visible = _fitFilter && ramKnown
        ? merged.where(
            (CatalogModelEntry m) => catalogModelFits(m.ramEstBytes, ram),
          )
        : merged;
    return ListView(
      key: const Key('ollama-catalog-list'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        TextField(
          key: const Key('ollama-custom-url'),
          controller: _customUrl,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: strings.ollamaCustomUrlLabel,
            hintText: 'https://example.com/model.gguf',
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: FilledButton.tonalIcon(
                key: const Key('ollama-custom-download'),
                onPressed: _downloadCustomUrl,
                icon: const Icon(Icons.link_rounded, size: 18),
                label: Text(strings.ollamaDownload),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('ollama-import'),
                onPressed: _importFromFile,
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: Text(strings.ollamaImportButton),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // v1.52.0 — remote catalog refresh + reset (only once applied).
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('ollama-catalog-refresh'),
                onPressed: _catalogRefreshing ? null : _refreshCatalog,
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: Text(strings.ollamaCatalogRefresh),
              ),
            ),
            if (models.remoteCatalog.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('ollama-catalog-reset'),
                  onPressed: _resetCatalog,
                  icon: const Icon(Icons.restore, size: 18),
                  label: Text(strings.ollamaCatalogReset),
                ),
              ),
            ],
          ],
        ),
        if (ramKnown) ...<Widget>[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              key: const Key('ollama-fit-filter'),
              label: Text(strings.ollamaFitFilter),
              selected: _fitFilter,
              onSelected: (bool value) => setState(() => _fitFilter = value),
            ),
          ),
        ],
        const SizedBox(height: 4),
        for (final CatalogModelEntry model in visible)
          _catalogCard(
            strings,
            model,
            installed: installedRefs.contains(model.ollamaRef),
            active: activeNames.contains(model.ollamaRef),
            fits: !ramKnown || catalogModelFits(model.ramEstBytes, ram),
          ),
      ],
    );
  }

  Widget _catalogCard(
    AppStrings strings,
    CatalogModelEntry model, {
    required bool installed,
    required bool active,
    required bool fits,
  }) => Card(
    key: Key('ollama-catalog-${model.ollamaRef}'),
    margin: const EdgeInsets.symmetric(vertical: 6),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  model.ollamaRef,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!fits) ...<Widget>[
                _tooLargeChip(strings),
                const SizedBox(width: 6),
              ],
              _tierChip(strings, model.tier),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${_fmtBytes(model.downloadBytes)} · '
            '${strings.ollamaRamEst(_fmtBytes(model.ramEstBytes))} · '
            '${strings.ollamaCtxTokens(_fmtTokens(model.contextTokens))}',
            style: const TextStyle(
              fontSize: 11.5,
              color: _kGrey,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          if (model.tier == CatalogTier.upperBound || !fits) ...<Widget>[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Icon(Icons.memory_rounded, size: 14, color: _kRed),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    !fits ? strings.ollamaTooLarge : strings.ollamaOomWarning,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: _kRed,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              FilledButton.tonalIcon(
                key: Key('ollama-download-${model.ollamaRef}'),
                onPressed: installed || active
                    ? null
                    : () => _downloadCatalogEntry(model),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text(
                  installed
                      ? strings.ollamaInstalledLabel
                      : active
                      ? strings.ollamaDownloadingLabel
                      : strings.ollamaDownload,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  /// v1.52.0 — red “Too large for this device” chip on non-fitting cards.
  Widget _tooLargeChip(AppStrings strings) => Container(
    key: const Key('ollama-too-large-chip'),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: _kRed.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      strings.ollamaTooLarge,
      style: const TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: _kRed,
      ),
    ),
  );

  Widget _tierChip(AppStrings strings, CatalogTier tier) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: _tierColor(tier).withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      _tierLabel(strings, tier),
      style: TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: _tierColor(tier),
      ),
    ),
  );

  // -- Installed tab -------------------------------------------------------------

  Widget _installedTab(BuildContext context, WidgetRef ref) {
    final AppStrings strings = _strings;
    final ZPalette palette = context.palette;
    final LocalModelState models = ref.watch(localModelsProvider);
    if (models.installed.isEmpty) {
      return ListView(
        key: const Key('ollama-installed-list'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          Card(
            key: const Key('ollama-installed-empty'),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: <Widget>[
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 32,
                    color: palette.muted,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.ollamaInstalledEmptyTitle,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    strings.ollamaInstalledEmptyBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: palette.muted,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return ListView(
      key: const Key('ollama-installed-list'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        for (final LocalModelEntry entry in models.installed)
          _installedCard(context, strings, palette, entry),
      ],
    );
  }

  Widget _installedCard(
    BuildContext context,
    AppStrings strings,
    ZPalette palette,
    LocalModelEntry entry,
  ) {
    final bool checked = _selectedIds.contains(entry.id);
    return Card(
      key: Key('ollama-installed-${entry.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                // v1.52.0 — bulk selection mode replaces the meta row's
                // leading edge with a checkbox; tapping the card toggles.
                if (_selectionMode) ...<Widget>[
                  Checkbox(
                    key: Key('ollama-select-${entry.id}'),
                    value: checked,
                    onChanged: (bool? value) =>
                        _toggleSelected(entry.id, value),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    entry.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: palette.muted.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _sourceLabel(strings, entry.source),
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: palette.muted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              <String>[
                if (entry.sizeBytes > 0) _fmtBytes(entry.sizeBytes),
                strings.ollamaAddedAt(_fmtDate(entry.addedAtMs)),
              ].join(' · '),
              style: const TextStyle(
                fontSize: 11.5,
                color: _kGrey,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
            if (!_selectionMode)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  IconButton(
                    key: Key('ollama-start-${entry.id}'),
                    tooltip: strings.ollamaStartWith,
                    icon: const Icon(Icons.play_arrow_rounded),
                    onPressed: () {
                      // Select + start, then hop to the Server tab so the
                      // user watches the status card come alive.
                      setState(() => _selectedModelId = entry.id);
                      _tabs.animateTo(0);
                      _startModel(entry);
                    },
                  ),
                  IconButton(
                    key: Key('ollama-export-${entry.id}'),
                    tooltip: strings.ollamaExport,
                    icon: const Icon(Icons.ios_share_rounded),
                    onPressed: () => _exportModel(entry),
                  ),
                  IconButton(
                    key: Key('ollama-delete-${entry.id}'),
                    tooltip: strings.delete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _confirmDeleteInstalled(entry),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // -- Downloads tab -------------------------------------------------------------

  Widget _downloadsTab(BuildContext context, WidgetRef ref) {
    final AppStrings strings = _strings;
    final List<DownloadProgress> downloads = ref.watch(downloadQueueProvider);
    final bool hasFinished = downloads.any(
      (DownloadProgress d) =>
          d.status == DownloadStatus.completed ||
          d.status == DownloadStatus.failed ||
          d.status == DownloadStatus.canceled,
    );
    return ListView(
      key: const Key('ollama-downloads-list'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        if (downloads.isEmpty)
          Card(
            key: const Key('ollama-downloads-empty'),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: <Widget>[
                  Icon(
                    Icons.download_outlined,
                    size: 32,
                    color: context.palette.muted,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.ollamaDownloadsEmpty,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          )
        else ...<Widget>[
          for (final DownloadProgress d in downloads) _downloadCard(strings, d),
          if (hasFinished)
            OutlinedButton.icon(
              key: const Key('ollama-clear-finished'),
              onPressed: () =>
                  ref.read(downloadQueueProvider.notifier).clearFinished(),
              icon: const Icon(Icons.clear_all_rounded, size: 18),
              label: Text(strings.ollamaClearFinished),
            ),
        ],
      ],
    );
  }

  Widget _downloadCard(AppStrings strings, DownloadProgress d) => Card(
    key: Key('ollama-download-row-${d.modelId}'),
    margin: const EdgeInsets.symmetric(vertical: 6),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  d.modelName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _dlStatusColor(d.status).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _dlStatusLabel(strings, d.status),
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: _dlStatusColor(d.status),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            key: Key('ollama-progress-${d.modelId}'),
            minHeight: 5,
            borderRadius: BorderRadius.circular(3),
            // Indeterminate while the total size is unknown.
            value: d.totalBytes > 0
                ? (d.receivedBytes / d.totalBytes).clamp(0.0, 1.0)
                : null,
          ),
          const SizedBox(height: 6),
          Text(
            d.totalBytes > 0
                ? strings.ollamaSizeProgress(
                    (d.receivedBytes / 1024 / 1024).round(),
                    (d.totalBytes / 1024 / 1024).round(),
                  )
                : '${(d.receivedBytes / 1024 / 1024).round()} MB',
            style: const TextStyle(
              fontSize: 11.5,
              color: _kGrey,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          if (d.status == DownloadStatus.failed &&
              (d.error ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              d.error!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: _kRed),
            ),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              if (d.status == DownloadStatus.paused)
                IconButton(
                  key: Key('ollama-resume-${d.modelId}'),
                  tooltip: strings.ollamaResume,
                  icon: const Icon(Icons.play_arrow_rounded),
                  onPressed: () => ref
                      .read(downloadQueueProvider.notifier)
                      .resume(d.modelId),
                ),
              if (d.status == DownloadStatus.queued ||
                  d.status == DownloadStatus.running)
                IconButton(
                  key: Key('ollama-pause-${d.modelId}'),
                  tooltip: strings.ollamaPause,
                  icon: const Icon(Icons.pause_rounded),
                  onPressed: () =>
                      ref.read(downloadQueueProvider.notifier).pause(d.modelId),
                ),
              if (d.status == DownloadStatus.queued ||
                  d.status == DownloadStatus.running ||
                  d.status == DownloadStatus.paused)
                IconButton(
                  key: Key('ollama-cancel-${d.modelId}'),
                  tooltip: strings.cancel,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => ref
                      .read(downloadQueueProvider.notifier)
                      .cancel(d.modelId),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

// -- Pure format helpers -------------------------------------------------------

/// Formats byte sizes for the catalog/installed cards: MB below 1 GB (no
/// decimals from 100 MB up), one decimal in GB above.
String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  final double mb = bytes / (1024 * 1024);
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  if (mb >= 100) return '${mb.round()} MB';
  return '${mb.toStringAsFixed(1)} MB';
}

/// Compact context-token label: 40960 → "40K".
String _fmtTokens(int tokens) =>
    tokens >= 1024 ? '${(tokens / 1024).round()}K' : '$tokens';

/// yyyy-mm-dd for the "Added" line of installed models.
String _fmtDate(int ms) {
  final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

String _serverStatusLabel(AppStrings strings, LlmServerStatus status) =>
    switch (status) {
      LlmServerStatus.unavailable => strings.ollamaStatusUnavailable,
      LlmServerStatus.stopped => strings.ollamaStatusStopped,
      LlmServerStatus.starting => strings.ollamaStatusStarting,
      LlmServerStatus.running => strings.ollamaStatusRunning,
      LlmServerStatus.stopping => strings.ollamaStatusStopping,
      LlmServerStatus.failed => strings.ollamaStatusFailed,
    };

Color _serverStatusColor(LlmServerStatus status) => switch (status) {
  LlmServerStatus.unavailable => _kGrey,
  LlmServerStatus.stopped => _kGrey,
  LlmServerStatus.starting => _kAmber,
  LlmServerStatus.running => _kGreen,
  LlmServerStatus.stopping => _kAmber,
  LlmServerStatus.failed => _kRed,
};

String _tierLabel(AppStrings strings, CatalogTier tier) => switch (tier) {
  CatalogTier.tier1 => strings.ollamaTierLight,
  CatalogTier.tier2 => strings.ollamaTierMedium,
  CatalogTier.upperBound => strings.ollamaTierHeavy,
};

Color _tierColor(CatalogTier tier) => switch (tier) {
  CatalogTier.tier1 => _kGreen,
  CatalogTier.tier2 => _kAmber,
  CatalogTier.upperBound => _kRed,
};

String _sourceLabel(AppStrings strings, LocalModelSource source) =>
    switch (source) {
      LocalModelSource.catalog => strings.ollamaSourceCatalog,
      LocalModelSource.customUrl => strings.ollamaSourceCustomUrl,
      LocalModelSource.imported => strings.ollamaSourceImported,
    };

String _dlStatusLabel(AppStrings strings, DownloadStatus status) =>
    switch (status) {
      DownloadStatus.queued => strings.ollamaDlQueued,
      DownloadStatus.running => strings.ollamaDlRunning,
      DownloadStatus.paused => strings.ollamaDlPaused,
      DownloadStatus.completed => strings.ollamaDlCompleted,
      DownloadStatus.failed => strings.ollamaDlFailed,
      DownloadStatus.canceled => strings.ollamaDlCanceled,
    };

Color _dlStatusColor(DownloadStatus status) => switch (status) {
  DownloadStatus.queued => _kGrey,
  DownloadStatus.running => kAccentColor,
  DownloadStatus.paused => _kAmber,
  DownloadStatus.completed => _kGreen,
  DownloadStatus.failed => _kRed,
  DownloadStatus.canceled => _kGrey,
};

/// v1.52.0 — full-screen server-log viewer: monospace, scrollable,
/// auto-scrolled to the bottom on open, Copy-all (system clipboard) and
/// Close. Read-only; the lines are a snapshot of `LlmServerState.logTail`
/// (already capped at 200 by the platform).
class _LogViewerScreen extends StatefulWidget {
  const _LogViewerScreen({required this.lines});

  final List<String> lines;

  @override
  State<_LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<_LogViewerScreen> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Auto-scroll to the bottom once the first frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _copyAll() async {
    final AppStrings strings = stringsOf(context);
    await Clipboard.setData(ClipboardData(text: widget.lines.join('\n')));
    if (!mounted) return;
    showAppMessage(context, strings.copied);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(strings.ollamaLogTitle),
        actions: <Widget>[
          TextButton.icon(
            key: const Key('ollama-log-viewer-copy'),
            onPressed: _copyAll,
            icon: const Icon(Icons.copy_all, size: 18),
            label: Text(strings.ollamaCopyAll),
          ),
          IconButton(
            key: const Key('ollama-log-viewer-close'),
            tooltip: strings.ollamaClose,
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Container(
            key: const Key('ollama-log-viewer-body'),
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.zSurfaceAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.zBorder),
            ),
            child: Text(
              widget.lines.join('\n'),
              style: const TextStyle(
                fontSize: 10.5,
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
