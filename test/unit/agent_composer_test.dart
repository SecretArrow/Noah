import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/agent_composer.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

void main() {
  LlmConfig config() => const LlmConfig(
    baseUrl: 'https://provider.test/v1',
    apiKey: 'key',
    model: 'test-model',
  );

  AgentComposeRequest request([
    String? context,
    List<String> avoid = const <String>[],
  ]) => AgentComposeRequest(
    task: 'chat-reply',
    context: context ?? 'the leaderboard reset today',
    avoid: avoid,
  );

  group('ComposerGate.validate', () {
    test('a clean casual sentence passes', () {
      final ComposerVerdict verdict = ComposerGate.validate(
        'the leaderboard reset is such a nice touch',
        maxWords: 24,
        trailingPeriod: false,
      );
      expect(verdict.ok, isTrue);
    });

    test('forbidden characters are flagged', () {
      final List<String> bad = <String>[
        'wow that is great!',
        'here is the thing: check it',
        'count me in; second row',
        'first try — no wait, second',
        'top tier – really',
      ];
      expect(bad.join(), contains('!'), reason: 'test data must stay honest');
      for (final String text in bad) {
        final ComposerVerdict verdict = ComposerGate.validate(
          text,
          maxWords: 24,
          trailingPeriod: false,
        );
        expect(verdict.ok, isFalse, reason: '"$text" must violate the rules');
      }
    });

    test('internal sentence punctuation is flagged', () {
      expect(
        ComposerGate.validate(
          'nice one. congrats on the win',
          maxWords: 24,
          trailingPeriod: false,
        ).ok,
        isFalse,
      );
      expect(
        ComposerGate.validate(
          'who made this?',
          maxWords: 24,
          trailingPeriod: false,
        ).ok,
        isFalse,
      );
    });

    test('a trailing period is only allowed when asked for', () {
      expect(
        ComposerGate.validate(
          'adds a progress bar to every list.',
          maxWords: 24,
          trailingPeriod: true,
        ).ok,
        isTrue,
      );
      expect(
        ComposerGate.validate(
          'adds a progress bar to every list.',
          maxWords: 24,
          trailingPeriod: false,
        ).ok,
        isFalse,
      );
    });

    test('emoji and word budget violations are flagged', () {
      expect(
        ComposerGate.validate(
          'this is amazing \u{1F600}',
          maxWords: 24,
          trailingPeriod: false,
        ).ok,
        isFalse,
      );
      expect(
        ComposerGate.validate(
          'one two three four five six seven eight nine ten eleven twelve '
          'thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty '
          'twentyone twentytwowords twentythree twentyfour twentyfive',
          maxWords: 24,
          trailingPeriod: false,
        ).ok,
        isFalse,
      );
    });

    test('repeating an avoided text is flagged (normalized)', () {
      final ComposerVerdict verdict = ComposerGate.validate(
        '  enjoy   the   weekend  everyone ',
        maxWords: 24,
        trailingPeriod: false,
        avoid: <String>['enjoy the weekend everyone'],
      );
      expect(verdict.violations, contains('repeats an earlier text'));
    });

    test('empty output is flagged', () {
      expect(
        ComposerGate.validate('   ', maxWords: 24, trailingPeriod: false).ok,
        isFalse,
      );
    });
  });

  group('ComposerGate.sanitize', () {
    test('strips wrapping quotes and forbidden characters', () {
      final String out = ComposerGate.sanitize(
        '"great update, thanks for that"',
        maxWords: 24,
        trailingPeriod: false,
      );
      expect(out, 'great update, thanks for that');
    });

    test('replaces forbidden punctuation and drops emoji', () {
      final String out = ComposerGate.sanitize(
        'need one thing \u{1F600} more save options here',
        maxWords: 24,
        trailingPeriod: false,
      );
      expect(out, contains('more save options'));
      expect(ComposerGate.forbidden.hasMatch(out), isFalse);
      expect(ComposerGate.emoji.hasMatch(out), isFalse);
    });

    test('cuts to the word budget', () {
      final String out = ComposerGate.sanitize(
        'a b c d e f g h i j k l m n o p q r s t u v w x y z',
        maxWords: 10,
        trailingPeriod: false,
      );
      expect(ComposerGate.wordCount(out), 10);
    });

    test('keeps a single trailing period when asked', () {
      final String out = ComposerGate.sanitize(
        'adds a small search box above the list.',
        maxWords: 24,
        trailingPeriod: true,
      );
      expect(out, endsWith('.'));
      expect(out.substring(0, out.length - 1), isNot(contains('.')));
    });
  });

  group('AgentComposer (agent-backed, chat LLM)', () {
    test('a valid first attempt needs exactly one LLM call', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'the challenge board is getting really good'),
      ]);
      final String text = await AgentComposer(llm: llm)
          .compose(request: request(), config: config());
      expect(text, 'the challenge board is getting really good');
      expect(llm.calls, hasLength(1));
      // The wire carries the regulated system prompt + the live context.
      expect(llm.calls.single.first['role'], 'system');
      expect(
        llm.calls.single.first['content'],
        contains('Never use the characters'),
      );
      expect(llm.calls.single.last['content'], contains('leaderboard'));
    });

    test(
      'a rule-breaking first attempt triggers the corrective retry',
      () async {
        final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(content: 'this is amazing!'),
          AssistantTurn(content: 'the new tier list is honestly so fun'),
        ]);
        final String text = await AgentComposer(llm: llm)
            .compose(request: request(), config: config());
        expect(text, 'the new tier list is honestly so fun');
        expect(llm.calls, hasLength(2));
        // The retry names the violation inside the user message.
        expect(llm.calls.last.last['content'], contains('violated the rules'));
      },
    );

    test('repeats are retried against the avoid list', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'enjoy the weekend everyone'),
        AssistantTurn(content: 'weekend mode is on here too'),
      ]);
      final String text = await AgentComposer(llm: llm).compose(
        request: request(null, <String>['enjoy the weekend everyone']),
        config: config(),
      );
      expect(text, 'weekend mode is on here too');
      expect(llm.calls, hasLength(2));
    });

    test('persistent violations fall back to deterministic sanitize', () async {
      // BOTH attempts break a repairable rule (an internal '!') — the
      // gate sanitizes the second attempt instead of failing the caller.
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'wow!'),
        AssistantTurn(content: 'this update is so good!'),
      ]);
      final String text = await AgentComposer(llm: llm)
          .compose(request: request(), config: config());
      expect(text, 'this update is so good');
      expect(llm.calls, hasLength(2));
    });

    test('wrapping quotes are pre-cleaned before the gate', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: '"nice work, really smooth update"'),
      ]);
      final String text = await AgentComposer(llm: llm)
          .compose(request: request(), config: config());
      expect(text, 'nice work, really smooth update');
      expect(llm.calls, hasLength(1));
    });

    test('unrepairable output (duplicate) surfaces a composer error', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'enjoy the weekend everyone'),
        AssistantTurn(content: 'enjoy the weekend everyone'),
      ]);
      await expectLater(
        AgentComposer(llm: llm).compose(
          request: request(null, <String>['enjoy the weekend everyone']),
          config: config(),
        ),
        throwsA(isA<AgentComposeException>()),
      );
    });

    test(
      'provider failures propagate as exceptions for graceful skips',
      () async {
        final _ErrorLlmClient llm = _ErrorLlmClient();
        await expectLater(
          AgentComposer(llm: llm).compose(request: request(), config: config()),
          throwsA(isA<LlmException>()),
        );
      },
    );

    test('empty context is rejected before touching the LLM', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[]);
      await expectLater(
        AgentComposer(llm: llm).compose(
          request: const AgentComposeRequest(context: '   '),
          config: config(),
        ),
        throwsA(isA<AgentComposeException>()),
      );
      expect(llm.calls, isEmpty);
    });
  });
}

/// LLM test double that always fails like a real provider error would.
class _ErrorLlmClient implements LlmClient {
  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    throw LlmException('HTTP 500: provider exploded');
  }
}
