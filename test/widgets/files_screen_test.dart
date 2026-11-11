import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/main.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/file_system_service.dart';
import 'package:noah/services/session_sandbox.dart';

import '../../test/support/test_doubles.dart';

/// SessionSandbox test double that always hands out the static file service, so
/// widget tests never touch real IO.
class StaticSessionSandbox extends SessionSandbox {
  StaticSessionSandbox(this.fs)
    : super(resolveDocumentsDir: () async => Directory.systemTemp);

  final FileSystemService fs;

  @override
  FileSystemService fsFor(String? sessionId) => fs;

  @override
  Future<Directory> rootFor(String? sessionId) async => Directory.systemTemp;
}

/// In-memory FileSystemService for widget tests: the real service does
/// real IO which never completes inside the async test zone (its
/// logic is fully covered by unit tests).
class StaticFileSystemService extends FileSystemService {
  StaticFileSystemService()
    : super(resolveBaseDir: () async => Directory.systemTemp);

  final List<FsEntry> entries = <FsEntry>[];
  final List<String> createdFolders = <String>[];

  @override
  Future<List<FsEntry>> list(String relative) async =>
      relative.isEmpty ? entries : const <FsEntry>[];

  @override
  Future<bool> exists(String relative) async => true;

  @override
  Future<void> mkdir(String relative) async => createdFolders.add(relative);

  @override
  Future<void> rename(String relative, String newName) async {}

  @override
  Future<void> delete(String relative) async {
    entries.removeWhere((FsEntry e) => e.relativePath == relative);
  }

  @override
  Future<void> copy(String srcRelative, String destRelative) async {}

  @override
  Future<void> move(String srcRelative, String destRelative) async {
    entries.removeWhere((FsEntry e) => e.relativePath == srcRelative);
  }

  @override
  Future<String> zip(String srcRelative) async => '$srcRelative.zip';

  /// When set, [unzip] behaves like an encrypted archive needing this
  /// password: null/empty -> password required, wrong -> wrong password.
  String? requiredPassword;

  final List<String> extractedWithPassword = <String>[];

  @override
  Future<String> unzip(
    String zipRelative, {
    String? destName,
    String? password,
  }) async {
    final String? required = requiredPassword;
    if (required != null && zipRelative.endsWith('.zip')) {
      if (password == null || password.isEmpty) {
        throw ZipPasswordRequiredException(zipRelative);
      }
      if (password != required) {
        throw const ZipWrongPasswordException();
      }
      extractedWithPassword.add(zipRelative);
      return zipRelative;
    }
    return destName ?? zipRelative;
  }

  @override
  Future<String> readText(String relative, {int maxChars = 20000}) async =>
      'preview text';
}

void main() {
  late Directory tempDir;
  late StaticFileSystemService fs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_files_test');
    fs = StaticFileSystemService();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> openFilesScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(dir: tempDir),
          // FilesScreen now browses the ACTIVE SESSION's workspace via
          // SessionSandbox — plug the static test double in there.
          sessionSandboxProvider.overrideWithValue(StaticSessionSandbox(fs)),
          activeSessionIdProvider.overrideWithValue('test-session'),
          chatListProvider.overrideWith(
            (Ref ref) async => const <ChatSummary>[],
          ),
        ],
        child: const NoahApp(),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.tap(find.byKey(const Key('drawer-files')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
  }

  testWidgets('files screen lists entries from the file service', (
    tester,
  ) async {
    fs.entries.add(
      FsEntry(
        name: 'hello.txt',
        relativePath: 'hello.txt',
        isDirectory: false,
        sizeBytes: 5,
        modified: DateTime(2025, 1, 1),
      ),
    );
    await openFilesScreen(tester);
    expect(find.byKey(const Key('file-hello.txt')), findsOneWidget);
  });

  testWidgets('files screen shows the empty state for a fresh app', (
    tester,
  ) async {
    await openFilesScreen(tester);
    expect(find.textContaining('No files yet'), findsOneWidget);
  });

  testWidgets('file search filters entries by name', (tester) async {
    FsEntry file(String name) => FsEntry(
      name: name,
      relativePath: name,
      isDirectory: false,
      sizeBytes: 1,
      modified: DateTime(2025, 1, 1),
    );
    fs.entries.addAll(<FsEntry>[file('report.txt'), file('photo.png')]);
    await openFilesScreen(tester);

    expect(find.byKey(const Key('file-report.txt')), findsOneWidget);
    expect(find.byKey(const Key('file-photo.png')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('files-search-field')),
      'report',
    );
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.byKey(const Key('file-report.txt')), findsOneWidget);
    expect(find.byKey(const Key('file-photo.png')), findsNothing);

    // No match shows the localized empty state.
    await tester.enterText(find.byKey(const Key('files-search-field')), 'zzz');
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.text('No results'), findsOneWidget);
  });

  testWidgets('new folder dialog reaches the service with the name', (
    tester,
  ) async {
    await openFilesScreen(tester);
    await tester.tap(find.byKey(const Key('files-new-folder')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.enterText(
      find.byKey(const Key('new-folder-field')),
      'exports',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(fs.createdFolders, contains('exports'));
  });

  testWidgets('cut an entry then paste shows the clipboard flow', (
    tester,
  ) async {
    fs.entries.add(
      FsEntry(
        name: 'move-me.txt',
        relativePath: 'move-me.txt',
        isDirectory: false,
        sizeBytes: 2,
        modified: DateTime(2025, 1, 1),
      ),
    );
    await openFilesScreen(tester);

    // Cut via the per-entry menu.
    await tester.tap(find.byKey(const Key('file-menu-move-me.txt')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.tap(find.text('Cut').last);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );

    // The paste button becomes enabled.
    final Finder paste = find.byKey(const Key('files-paste'));
    expect(tester.widget<IconButton>(paste).onPressed, isNotNull);
    await tester.tap(paste);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    // Pasting a CUT item into its own folder is a deliberate no-op:
    // the clipboard stays armed so the user can navigate elsewhere.
    expect(tester.widget<IconButton>(paste).onPressed, isNotNull);
  });

  testWidgets('delete entry flow removes it from the list', (tester) async {
    fs.entries.add(
      FsEntry(
        name: 'gone.txt',
        relativePath: 'gone.txt',
        isDirectory: false,
        sizeBytes: 1,
        modified: DateTime(2025, 1, 1),
      ),
    );
    await openFilesScreen(tester);
    await tester.tap(find.byKey(const Key('file-menu-gone.txt')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    // Confirm the dialog.
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.byKey(const Key('file-gone.txt')), findsNothing);
  });

  testWidgets('extracting an encrypted zip asks for a password (wrong first)', (
    tester,
  ) async {
    fs.requiredPassword = 'fixt-pass-42';
    fs.entries.add(
      FsEntry(
        name: 'secret.zip',
        relativePath: 'secret.zip',
        isDirectory: false,
        sizeBytes: 100,
        modified: DateTime(2025, 1, 1),
      ),
    );
    await openFilesScreen(tester);

    await tester.tap(find.byKey(const Key('file-menu-secret.zip')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.tap(find.text('Extract').last);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    // The password dialog appeared instead of extracting.
    expect(find.byKey(const Key('unzip-password-dialog')), findsOneWidget);

    // A wrong password surfaces the dedicated snackbar.
    await tester.enterText(
      find.byKey(const Key('unzip-password-field')),
      'nope',
    );
    await tester.tap(find.byKey(const Key('unzip-password-ok')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.text('Wrong password.'), findsOneWidget);
    expect(fs.extractedWithPassword, isEmpty);
  });

  testWidgets('extracting an encrypted zip succeeds with the right password', (
    tester,
  ) async {
    fs.requiredPassword = 'fixt-pass-42';
    fs.entries.add(
      FsEntry(
        name: 'secret.zip',
        relativePath: 'secret.zip',
        isDirectory: false,
        sizeBytes: 100,
        modified: DateTime(2025, 1, 1),
      ),
    );
    await openFilesScreen(tester);

    await tester.tap(find.byKey(const Key('file-menu-secret.zip')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.tap(find.text('Extract').last);
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.enterText(
      find.byKey(const Key('unzip-password-field')),
      'fixt-pass-42',
    );
    await tester.tap(find.byKey(const Key('unzip-password-ok')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(fs.extractedWithPassword, contains('secret.zip'));
    expect(find.text('Extracted.'), findsOneWidget);
  });

  testWidgets('files screen without an active chat asks to open one '
      '(v1.29.0: no shared-root mixing)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...testOverrides(dir: tempDir),
          sessionSandboxProvider.overrideWithValue(StaticSessionSandbox(fs)),
          chatListProvider.overrideWith(
            (Ref ref) async => const <ChatSummary>[],
          ),
          // NO activeSessionIdProvider override: the fresh app has no
          // open chat, so there is no per-chat workspace to browse.
        ],
        child: const NoahApp(),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    await tester.tap(find.byKey(const Key('drawer-files')));
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 10),
    );
    expect(find.textContaining('No chat open'), findsOneWidget);
    // The legacy shared root is NOT listed anymore.
    expect(find.byKey(const Key('files-new-folder')), findsNothing);
  });
}
