import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/make_plugins.dart';

void main() {
  group('matchMakePluginsCommand', () {
    test('matches the canonical command and returns the description', () {
      expect(
        matchMakePluginsCommand('/make_plugins daily quote plugin'),
        'daily quote plugin',
      );
    });

    test('matches with no description (empty remainder)', () {
      expect(matchMakePluginsCommand('/make_plugins'), '');
      expect(matchMakePluginsCommand('/make_plugins   '), '');
    });

    test('is case-insensitive and tolerates leading whitespace', () {
      expect(
        matchMakePluginsCommand('  /MAKE_PLUGINS weather bot'),
        'weather bot',
      );
      expect(matchMakePluginsCommand('\t/Make_Plugins x'), 'x');
    });

    test('supports singular and module aliases', () {
      expect(matchMakePluginsCommand('/make_plugin counter'), 'counter');
      expect(matchMakePluginsCommand('/make_module notes sync'), 'notes sync');
      expect(matchMakePluginsCommand('/make_modules'), '');
    });

    test('rejects lookalikes and ordinary messages', () {
      expect(matchMakePluginsCommand('/make_pluginsfoo'), isNull);
      expect(matchMakePluginsCommand('/make_pluginsx y'), isNull);
      expect(matchMakePluginsCommand('/plugins'), isNull);
      expect(matchMakePluginsCommand('make_plugins a counter'), isNull);
      expect(matchMakePluginsCommand('hello /make_plugins'), isNull);
      expect(matchMakePluginsCommand(''), isNull);
      expect(matchMakePluginsCommand('build me a plugin that counts'), isNull);
    });
  });

  group('makePluginsBuilderPrompt', () {
    test('embeds the user request verbatim', () {
      final String brief = makePluginsBuilderPrompt('a pomodoro plugin');
      expect(brief, contains('a pomodoro plugin'));
      expect(brief, startsWith('# Task: build a NEW Noah chat module'));
    });

    test('empty request instructs the model to ask first, not build', () {
      final String brief = makePluginsBuilderPrompt('');
      expect(brief, contains('do NOT build anything yet'));
      expect(brief, contains('asking 2-4 short questions'));
    });

    test('spec mirrors the real runtime contract', () {
      final String brief = makePluginsBuilderPrompt('x');
      // CommonJS-only entry (ES syntax is the classic module failure).
      expect(brief, contains('CommonJS'));
      expect(brief, contains('import` / `export'));
      // Permission names + SDK surface.
      for (final String perm in const <String>[
        'storage',
        'network',
        'files',
        'chat',
        'agent',
      ]) {
        expect(brief, contains(perm));
      }
      expect(brief, contains('zagents.http.request'));
      expect(brief, contains('zagents.agent.compose'));
      expect(brief, contains('zagents.info.setup'));
      // Manifest fields the registry actually parses.
      expect(brief, contains('allowedHosts'));
      expect(brief, contains('timeoutSeconds'));
      // Stage + trust boundary.
      expect(brief, contains('module_stage_repair'));
      expect(brief, contains('NEVER claim the plugin is installed'));
      // Session-data policy (use or not, copied INTO the module).
      expect(brief, contains('Session-data policy'));
      expect(brief, contains('self-contained'));
    });

    test('expandMakePluginsPrompt passes plain text through untouched', () {
      const String text = 'just a normal message /make_plugins-ish';
      expect(expandMakePluginsPrompt(text), same(text));
    });

    test('expandMakePluginsPrompt expands only the command message', () {
      final String expanded = expandMakePluginsPrompt('/make_plugin counter');
      expect(expanded, contains('# Task: build a NEW Noah chat module'));
      expect(expanded, contains('counter'));
      expect(expanded.contains('/make_plugin counter'), isFalse);
    });
  });

  group('isMakePluginsCommand', () {
    test('reflects the matcher', () {
      expect(isMakePluginsCommand('/make_plugins'), isTrue);
      expect(isMakePluginsCommand('/MAKE_MODULE a'), isTrue);
      expect(isMakePluginsCommand('/make_pluginsx'), isFalse);
      expect(isMakePluginsCommand('hi'), isFalse);
    });
  });
}
