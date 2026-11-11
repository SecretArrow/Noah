import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/skill_registry.dart';
import 'package:noah/services/tool_executor.dart';

import '../support/test_doubles.dart';

const String _bundledSkillMd = '''
---
name: binance-agentic-wallet
title: Binance Agentic Wallet
description: Official Binance wallet flow with explicit user confirmation for every asset-moving action.
version: "1.0"
permissions:
  - network
---

# Binance Agentic Wallet

Official-flow only. Never ask for seed phrases. Every asset-moving action
requires an explicit user confirmation.
''';

const String _walletSkillMd = '''
---
name: wallet-skill
title: Wallet Skill
description: Moves value on-chain.
version: "1.0"
wallet: true
permissions:
  - network
---

# Wallet Skill

Every asset-moving action requires explicit user confirmation.
''';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_builtin_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  SkillRegistry registry() =>
      SkillRegistry(resolveBaseDir: () async => tempDir);

  ToolExecutor executor() => ToolExecutor(
    browser: ScriptedBrowserAutomation(
      '${tempDir.path}${Platform.pathSeparator}shots',
      writeScreenshot: false,
    ),
    resolveBaseDir: (_) async => tempDir,
    isAutomationEnabled: () => false,
    skills: registry(),
    bundledSkills: () async => <String, String>{
      'binance-agentic-wallet': _bundledSkillMd,
      'web3-wallet-basics': _bundledSkillMd,
    },
  );

  group('SkillRegistry.installBundled', () {
    test('installs a bundled SKILL.md on disk without network', () async {
      final SkillRegistry reg = registry();
      final SkillInstallReport report = await reg.installBundled(
        bundledName: 'binance-agentic-wallet',
        skillMd: _bundledSkillMd,
      );
      expect(report.skill.name, 'binance-agentic-wallet');
      expect(report.skill.source, 'builtin:binance-agentic-wallet');
      // Real file on disk with the full instructions.
      final File md = File(
        '${report.skill.dirPath}${Platform.pathSeparator}SKILL.md',
      );
      expect(md.existsSync(), isTrue);
      expect(md.readAsStringSync(), contains('# Binance Agentic Wallet'));
      // Registered + readable via the normal API.
      final InstalledSkill? skill = await reg.get('binance-agentic-wallet');
      expect(skill, isNotNull);
      expect(skill!.readInstructions(), contains('Official-flow only'));
    });

    test('re-install replaces the previous version cleanly', () async {
      final SkillRegistry reg = registry();
      await reg.installBundled(
        bundledName: 'binance-agentic-wallet',
        skillMd: _bundledSkillMd,
      );
      await reg.installBundled(
        bundledName: 'binance-agentic-wallet',
        skillMd: _bundledSkillMd,
      );
      expect((await reg.list()), hasLength(1));
    });

    test('bundled SKILL.md without a name is rejected', () async {
      final SkillRegistry reg = registry();
      expect(
        () => reg.installBundled(
          bundledName: 'broken',
          skillMd: 'no front matter here',
        ),
        throwsA(isA<SkillRegistryException>()),
      );
    });

    test('the wallet flag is parsed from SKILL.md and persisted', () async {
      final SkillRegistry reg = registry();
      final SkillInstallReport wallet = await reg.installBundled(
        bundledName: 'wallet-skill',
        skillMd: _walletSkillMd,
      );
      expect(wallet.skill.wallet, isTrue);
      // A fresh registry reads it back from registry.json — the approval
      // gate must survive an app restart.
      final SkillRegistry reloaded = registry();
      final InstalledSkill? stored = await reloaded.get('wallet-skill');
      expect(stored, isNotNull);
      expect(stored!.wallet, isTrue);
    });

    test('a skill without the flag is not value-moving', () async {
      final SkillRegistry reg = registry();
      final SkillInstallReport plain = await reg.installBundled(
        bundledName: 'binance-agentic-wallet',
        skillMd: _bundledSkillMd,
      );
      expect(plain.skill.wallet, isFalse);
    });
  });

  group('skill_install builtin:<name>', () {
    test(
      'installs through the executor and reports success honestly',
      () async {
        final ToolExecutor ex = executor();
        final ToolResult result = await ex.execute(
          'skill_install',
          <String, dynamic>{'source': 'builtin:binance-agentic-wallet'},
        );
        expect(result.ok, isTrue, reason: result.llmOutput);
        expect(result.llmOutput, contains('Installed skill'));
        expect(result.llmOutput, contains('binance-agentic-wallet'));
        // Verify via skill_info: the instructions are really readable.
        final ToolResult info = await ex.execute(
          'skill_info',
          <String, dynamic>{'name': 'binance-agentic-wallet'},
        );
        expect(info.ok, isTrue);
        expect(info.llmOutput, contains('Official-flow only'));
      },
    );

    test('unknown bundled name fails with the available names', () async {
      final ToolExecutor ex = executor();
      final ToolResult result = await ex.execute(
        'skill_install',
        <String, dynamic>{'source': 'builtin:does-not-exist'},
      );
      expect(result.ok, isFalse);
      expect(result.llmOutput, contains('No bundled skill'));
      expect(result.llmOutput, contains('binance-agentic-wallet'));
    });
  });
}
