import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/services/module_registry.dart';
import 'package:noah/ui/screens/modules_screen.dart';

import '../support/test_doubles.dart';

import 'package:noah/services/module_remote.dart';

/// In-memory ModuleRegistry test double: no disk IO inside the async test
/// zone, records every mutation for assertions.
class ScriptedModuleRegistry extends ModuleRegistry {
  ScriptedModuleRegistry()
    : super(resolveBaseDir: () async => Directory.systemTemp);

  final Map<String, ChatModule> modules = <String, ChatModule>{};
  final List<String> removed = <String>[];
  final List<String> installAttempts = <String>[];

  /// v1.47.0 — export targets recorded in call order; [exportResult]
  /// scripts the outcome (defaults to a successful export). No disk IO
  /// happens: the share sheet path then fails in the test zone and is
  /// swallowed by the screen's failure snack.
  final List<String> exportCalls = <String>[];
  ModuleExportResult? exportResult;

  void seed(ChatModule module) => modules[module.name] = module;

  @override
  Future<List<ChatModule>> listInstalled() async =>
      modules.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  @override
  Future<ChatModule?> get(String name) async =>
      modules[ModuleManifest.sanitizeName(name)];

  @override
  ChatModule? getSync(String name) =>
      modules[ModuleManifest.sanitizeName(name)];

  @override
  Future<void> ensureCacheLoaded() async {}

  @override
  Future<bool> remove(String name) async {
    removed.add(name);
    return modules.remove(ModuleManifest.sanitizeName(name)) != null;
  }

  @override
  Future<ModuleInstallResult> installFromZip(String zipPath) async {
    installAttempts.add(zipPath);
    return ModuleInstallResult(ok: false, message: 'not scripted');
  }

  @override
  Future<ModuleExportResult> exportToZip(String name, String targetPath) async {
    exportCalls.add(targetPath);
    return exportResult ??
        ModuleExportResult(
          ok: true,
          message: 'Exported $name (scripted)',
          zipPath: targetPath,
          fileCount: 1,
        );
  }
}

/// v1.46.0 — scripted remote intake double: no network in the widget
/// test zone. Versions come from a map, installs return a scripted
/// result, every call is recorded for assertions.
class FakeModuleRemote extends ModuleRemote {
  FakeModuleRemote({
    required super.registry,
    this.versions = const <String, String?>{},
    this.installResult,
  });

  final Map<String, String?> versions;
  ModuleInstallResult? installResult;
  final List<String> urlCalls = <String>[];
  final List<String> sampleCalls = <String>[];

  @override
  Future<ModuleInstallResult> installFromUrl(String url) async {
    urlCalls.add(url);
    return installResult ??
        ModuleInstallResult(
          ok: true,
          message: 'Installed fake v1.0.0',
          module: ChatModule(
            manifest: ModuleManifest(
              name: 'fake',
              version: '1.0.0',
              title: 'fake',
              description: '',
              entry: 'main.js',
            ),
            path: '/tmp/modules/fake',
            installedAt: DateTime(2026, 1, 1),
          ),
        );
  }

  @override
  Future<ModuleInstallResult> installSample(String name) async {
    sampleCalls.add(name);
    return installResult ??
        ModuleInstallResult(
          ok: true,
          message: 'Updated $name v1.0.0 → v2.0.0',
          module: ChatModule(
            manifest: ModuleManifest(
              name: ModuleManifest.sanitizeName(name),
              version: '2.0.0',
              title: name,
              description: '',
              entry: 'main.js',
            ),
            path: '/tmp/modules/$name',
            installedAt: DateTime(2026, 1, 1),
          ),
        );
  }

  @override
  Future<String?> sampleRemoteVersion(String name) async => versions[name];
}

ChatModule _module(
  String name, {
  List<ModulePermission> permissions = const <ModulePermission>[
    ModulePermission.storage,
  ],
}) {
  return ChatModule(
    manifest: ModuleManifest(
      name: name,
      version: '2.5.0',
      title: name,
      description: '$name description',
      entry: 'main.js',
      permissions: permissions.toSet(),
    ),
    path: '/tmp/modules/$name',
    installedAt: DateTime(2026, 1, 1),
  );
}

Widget _host(
  List<Override> overrides,
  Directory tempDir, {
  required ModuleRemote remote,
}) => ProviderScope(
  overrides: <Override>[
    // Full app override set (settings repo, lock, JS runtime, ...) —
    // the SDK docs viewer reads the language preference.
    ...testOverrides(dir: tempDir, writeScreenshots: false),
    // The catalog probes/installs through this double — never the real
    // network (tests that need scripting pass their own via [remote]).
    moduleRemoteProvider.overrideWithValue(remote),
    ...overrides,
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      zLocalizationsDelegate,
    ],
    supportedLocales: const <Locale>[Locale('en'), Locale('id')],
    home: const ModulesScreenHost(),
  ),
);

/// Pushes [ModulesScreen] so its AppBar/actions render inside a navigator.
class ModulesScreenHost extends StatelessWidget {
  const ModulesScreenHost({super.key});

  @override
  Widget build(BuildContext context) => const ModulesScreen();
}

void main() {
  late ScriptedModuleRegistry registry;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('modules_screen_test');
    registry = ScriptedModuleRegistry();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  testWidgets('modules screen lists installed modules with versions and '
      'permissions', (WidgetTester tester) async {
    registry.seed(_module('alpha'));
    registry.seed(_module('beta', permissions: <ModulePermission>[]));
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: FakeModuleRemote(registry: registry),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('module-tile-alpha')), findsOneWidget);
    expect(find.text('v2.5.0'), findsNWidgets(2));
    expect(find.text('alpha description'), findsOneWidget);
    expect(find.text('storage'), findsOneWidget);
  });

  testWidgets('empty state shows the install hint', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: FakeModuleRemote(registry: registry),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No modules installed yet.'), findsOneWidget);
    expect(find.byKey(const Key('modules-install')), findsOneWidget);
  });

  testWidgets('remove flow: confirm dialog deletes the module', (
    WidgetTester tester,
  ) async {
    registry.seed(_module('alpha'));
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: FakeModuleRemote(registry: registry),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('module-remove-alpha')));
    await tester.pumpAndSettle();
    expect(find.text('Remove module?'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(registry.removed, <String>['alpha']);
    expect(find.byKey(const Key('module-tile-alpha')), findsNothing);
  });

  testWidgets('SDK documentation opens and renders the shipped asset', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: FakeModuleRemote(registry: registry),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('modules-sdk-docs')));
    await tester.pumpAndSettle();

    expect(find.text('SDK documentation'), findsOneWidget);
    expect(find.textContaining('Noah Module SDK'), findsWidgets);
  });

  testWidgets('permission consent dialog lists requested capabilities and '
      'returns the decision', (WidgetTester tester) async {
    final ChatModule mod = _module('alpha');
    bool? allowed;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            zLocalizationsDelegate,
          ],
          supportedLocales: const <Locale>[Locale('en'), Locale('id')],
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) => TextButton(
              onPressed: () async {
                allowed = await ModulesScreen.confirmPermissions(
                  context,
                  ref,
                  mod,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Allow \u201calpha\u201d to:'), findsOneWidget);
    expect(find.text('storage'), findsOneWidget);

    await tester.tap(find.byKey(const Key('module-permission-allow')));
    await tester.pumpAndSettle();
    expect(allowed, isTrue);
  });

  testWidgets('consent is skipped for modules without permissions', (
    WidgetTester tester,
  ) async {
    final ChatModule mod = _module('bare', permissions: <ModulePermission>[]);
    bool? allowed;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            zLocalizationsDelegate,
          ],
          supportedLocales: const <Locale>[Locale('en'), Locale('id')],
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) => TextButton(
              onPressed: () async {
                allowed = await ModulesScreen.confirmPermissions(
                  context,
                  ref,
                  mod,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(allowed, isTrue);
  });

  testWidgets('URL install flow: dialog hands the URL to the remote intake '
      'and reports the failure verbatim', (WidgetTester tester) async {
    final FakeModuleRemote remote = FakeModuleRemote(
      registry: registry,
      installResult: const ModuleInstallResult(
        ok: false,
        message: 'Only HTTPS module URLs are allowed',
      ),
    );
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: remote,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('modules-install-url')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('module-url-dialog')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('module-url-field')),
      'http://example.com/mod.zip',
    );
    await tester.tap(find.byKey(const Key('module-url-download')));
    await tester.pumpAndSettle();

    expect(remote.urlCalls, <String>['http://example.com/mod.zip']);
    expect(
      find.text('Install failed: Only HTTPS module URLs are allowed'),
      findsOneWidget,
    );
  });

  testWidgets('catalog shows Update for a newer official sample and '
      'installs it on tap', (WidgetTester tester) async {
    registry.seed(_module('counter'));
    final FakeModuleRemote remote = FakeModuleRemote(
      registry: registry,
      // The _module() helper stamps installed modules as v2.5.0 — the
      // remote probe must report something newer for the Update badge.
      versions: <String, String?>{'counter': '2.6.0'},
    );
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: remote,
      ),
    );
    await tester.pumpAndSettle();

    // Tall viewport: the whole list (module card + catalog) builds at
    // once, so no scrolling gymnastics are needed in the test zone.
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();

    // counter v2.5.0 installed, remote 2.6.0 → Update accent action.
    expect(find.byKey(const Key('sample-update-counter')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sample-update-counter')));
    await tester.pumpAndSettle();

    expect(remote.sampleCalls, <String>['counter']);
    expect(find.text('Updated counter v1.0.0 → v2.0.0'), findsOneWidget);
  });

  testWidgets('catalog offers Install for samples that are not installed '
      'and reports success', (WidgetTester tester) async {
    // One unrelated install keeps the screen in LIST mode — the official
    // catalog footer only renders alongside installed modules.
    registry.seed(_module('alpha'));
    final FakeModuleRemote remote = FakeModuleRemote(registry: registry);
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: remote,
      ),
    );
    await tester.pumpAndSettle();

    // Tall viewport: the whole list (module card + catalog) builds at
    // once, so no scrolling gymnastics are needed in the test zone.
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sample-install-counter')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sample-install-counter')));
    await tester.pumpAndSettle();

    expect(remote.sampleCalls, <String>['counter']);
    // The scripted sample install reports a version-aware update — the
    // snackbar surfaces it verbatim (same contract as the FAB intake).
    expect(find.text('Updated counter v1.0.0 → v2.0.0'), findsOneWidget);
  });

  testWidgets('per-module update sheet: From URL prefills the official '
      'repo ZIP for known samples', (WidgetTester tester) async {
    registry.seed(_module('counter'));
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: FakeModuleRemote(registry: registry),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('module-update-counter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('module-update-from-zip')), findsOneWidget);
    expect(find.byKey(const Key('module-update-from-url')), findsOneWidget);

    await tester.tap(find.byKey(const Key('module-update-from-url')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('module-url-dialog')), findsOneWidget);
    final TextField field = tester.widget<TextField>(
      find.byKey(const Key('module-url-field')),
    );
    expect(
      field.controller!.text,
      'https://raw.githubusercontent.com/SecretArrow/Noah/main/samples/'
      'counter.zip',
    );
  });

  testWidgets('per-module update sheet: From ZIP hands off to the file '
      'picker path', (WidgetTester tester) async {
    registry.seed(_module('counter'));
    await tester.pumpWidget(
      _host(
        <Override>[moduleRegistryProvider.overrideWithValue(registry)],
        tempDir,
        remote: FakeModuleRemote(registry: registry),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('module-update-counter')));
    await tester.pumpAndSettle();

    // The update body names the module and BOTH intake options are
    // offered. (The ZIP intake itself is exercised end-to-end by the
    // registry unit tests; driving the real file picker here would hang
    // the widget-test zone on the plugin channel.)
    expect(find.byKey(const Key('module-update-from-zip')), findsOneWidget);
    expect(find.byKey(const Key('module-update-from-url')), findsOneWidget);
    expect(find.textContaining('counter'), findsWidgets);

    // Dismiss the sheet via the barrier; the screen is back to idle.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('module-update-from-zip')), findsNothing);
  });

  group('export flow (v1.47.0)', () {
    Future<void> openExportDialog(WidgetTester tester) async {
      registry.seed(_module('counter'));
      await tester.pumpWidget(
        _host(
          <Override>[moduleRegistryProvider.overrideWithValue(registry)],
          tempDir,
          remote: FakeModuleRemote(registry: registry),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('module-export-counter')));
      await tester.pumpAndSettle();
    }

    testWidgets('rename dialog appears before any write, prefilled with the '
        'preset name and the freshness hint', (WidgetTester tester) async {
      await openExportDialog(tester);

      expect(find.byKey(const Key('module-export-dialog')), findsOneWidget);
      final TextField field = tester.widget<TextField>(
        find.byKey(const Key('module-export-name-field')),
      );
      // ModuleRegistry.presetZipFileName('counter', '2.5.0').
      expect(field.controller!.text, 'counter-v2.5.0.zip');
      expect(find.textContaining('fresh, installable ZIP'), findsOneWidget);
      // Nothing is written before the user confirms.
      expect(registry.exportCalls, isEmpty);
    });

    testWidgets('renamed export: the recorded target ends with the user '
        'file name', (WidgetTester tester) async {
      await openExportDialog(tester);

      // The prefill is fully selected on focus, so entering text replaces
      // it — appending -backup yields the renamed archive.
      await tester.enterText(
        find.byKey(const Key('module-export-name-field')),
        'counter-v2.5.0-backup.zip',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('module-export-confirm')));
      await tester.pumpAndSettle();

      expect(registry.exportCalls, hasLength(1));
      expect(
        registry.exportCalls.single,
        endsWith('counter-v2.5.0-backup.zip'),
      );
      expect(find.byKey(const Key('module-export-dialog')), findsNothing);
    });

    testWidgets('sanitizer: illegal characters are REMOVED, not replaced — '
        'my ../module:name becomes my ..modulename.zip', (
      WidgetTester tester,
    ) async {
      await openExportDialog(tester);

      await tester.enterText(
        find.byKey(const Key('module-export-name-field')),
        'my ../module:name',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('module-export-confirm')));
      await tester.pumpAndSettle();

      // '/' and ':' are stripped; the interior '..' and space survive
      // (harmless inside one flat file name); '.zip' is appended.
      expect(registry.exportCalls.single, endsWith('my ..modulename.zip'));
    });

    testWidgets('sanitizer: dot-only names fall back to the preset', (
      WidgetTester tester,
    ) async {
      await openExportDialog(tester);

      await tester.enterText(
        find.byKey(const Key('module-export-name-field')),
        '..',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('module-export-confirm')));
      await tester.pumpAndSettle();

      expect(registry.exportCalls.single, endsWith('counter-v2.5.0.zip'));
    });

    testWidgets('empty name disables the Export action and keeps the dialog '
        'open', (WidgetTester tester) async {
      await openExportDialog(tester);

      await tester.enterText(
        find.byKey(const Key('module-export-name-field')),
        '   ',
      );
      await tester.pump();

      final FilledButton confirm = tester.widget<FilledButton>(
        find.byKey(const Key('module-export-confirm')),
      );
      expect(confirm.onPressed, isNull);

      // Tapping the disabled action changes nothing.
      await tester.tap(find.byKey(const Key('module-export-confirm')));
      await tester.pumpAndSettle();
      expect(registry.exportCalls, isEmpty);
      expect(find.byKey(const Key('module-export-dialog')), findsOneWidget);
    });
  });
}
