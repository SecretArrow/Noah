import 'package:flutter_test/flutter_test.dart';
import 'package:noah/services/agent_polisher.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

void main() {
  LlmConfig config() => const LlmConfig(
    baseUrl: 'https://provider.test/v1',
    apiKey: 'key',
    model: 'test-model',
  );

  AgentPolishRequest request([
    String? template,
    String? context,
    List<String> avoid = const <String>[],
    int maxChars = 280,
  ]) => AgentPolishRequest(
    template: template ?? 'Halo {name}, makasih sudah menghubungi kami. Pesanmu sedang kami proses ya.',
    context:
        context ??
        'halo kak, kapan pesanan saya dikirim ya soalnya sudah 3 hari',
    avoid: avoid,
    maxChars: maxChars,
  );

  group('AgentPolishRequest', () {
    test('maxChars is clamped to the 20..500 window', () {
      expect(
        const AgentPolishRequest(
          template: 'a',
          context: 'b',
          maxChars: 1,
        ).clampedMaxChars,
        20,
      );
      expect(
        const AgentPolishRequest(
          template: 'a',
          context: 'b',
          maxChars: 9999,
        ).clampedMaxChars,
        500,
      );
      expect(
        const AgentPolishRequest(
          template: 'a',
          context: 'b',
          maxChars: 280,
        ).clampedMaxChars,
        280,
      );
    });

    test('default budget matches the X free-account limit', () {
      expect(AgentPolishRequest.defaultMaxChars, 280);
      expect(AgentPolishRequest.defaultTone, 'friendly');
    });
  });

  group('ReplyPolishGate.preClean', () {
    test('collapses newlines and extra spaces into one paragraph', () {
      expect(
        ReplyPolishGate.preClean('  Halo kak,\n\n  makasih   ya  '),
        'Halo kak, makasih ya',
      );
    });

    test('strips one layer of wrapping quotes or backticks', () {
      expect(
        ReplyPolishGate.preClean('"sudah kami proses"'),
        'sudah kami proses',
      );
      expect(
        ReplyPolishGate.preClean('`sudah kami proses`'),
        'sudah kami proses',
      );
      // nested quotes keep the inner layer
      expect(
        ReplyPolishGate.preClean('"sudah kami proses"'),
        'sudah kami proses',
      );
    });
  });

  group('ReplyPolishGate.validate', () {
    test('a natural multi-sentence reply passes', () {
      final PolisherVerdict verdict = ReplyPolishGate.validate(
        'Halo kak, makasih sudah sabar menunggu. Pesanan kamu hari ini kami '
        'kirim dan resinya menyusul ya. Kalau ada kendala kabur saja langsung ke sini.',
        maxChars: 280,
        allowEmoji: false,
        template:
            'Halo, makasih sudah menghubungi kami. Pesanan sedang diproses.',
        context: 'kapan pesanan saya dikirim?',
      );
      expect(verdict.ok, isTrue, reason: verdict.violations.join(', '));
    });

    test('question marks and periods are allowed (unlike compose)', () {
      final PolisherVerdict verdict = ReplyPolishGate.validate(
        'Boleh tahu nomor pesanannya kak? Nanti kami cek langsung ya.',
        maxChars: 280,
        allowEmoji: false,
        template: 'Boleh tahu nomor pesanan?',
        context: 'pesanan saya belum sampai',
      );
      expect(verdict.ok, isTrue, reason: verdict.violations.join(', '));
    });

    test('over the char budget is flagged', () {
      final PolisherVerdict verdict = ReplyPolishGate.validate(
        'a' * 281,
        maxChars: 280,
        allowEmoji: false,
        template: 'x',
        context: 'y',
      );
      expect(verdict.violations, contains('over 280 characters'));
    });

    test('emoji is flagged unless explicitly allowed', () {
      const String withEmoji = 'Siap kak, kami proses \u{1F600}';
      expect(
        ReplyPolishGate.validate(
          withEmoji,
          maxChars: 280,
          allowEmoji: false,
          template: 'Siap, kami proses',
          context: 'tolong diproses',
        ).violations,
        contains('emoji'),
      );
      expect(
        ReplyPolishGate.validate(
          withEmoji,
          maxChars: 280,
          allowEmoji: true,
          template: 'Siap, kami proses',
          context: 'tolong diproses',
        ).ok,
        isTrue,
      );
    });

    test('markdown artifacts are flagged', () {
      final List<String> bad = <String>[
        '**Siap kak** kami proses',
        '## Siap kak',
        'Siap `kami` proses',
        'ada | pipa di tengah',
        'Siap kak\n- kami proses',
        '__Siap__ kak',
      ];
      for (final String text in bad) {
        final PolisherVerdict verdict = ReplyPolishGate.validate(
          text,
          maxChars: 280,
          allowEmoji: false,
          template: 'Siap kak kami proses',
          context: 'tolong diproses',
        );
        expect(verdict.ok, isFalse, reason: '"$text" must violate the rules');
        expect(verdict.violations, contains('markdown formatting'));
      }
    });

    test('an unfilled template slot is flagged', () {
      final PolisherVerdict verdict = ReplyPolishGate.validate(
        'Halo {name}, pesananmu kami proses ya',
        maxChars: 280,
        allowEmoji: false,
        template: 'Halo, pesananmu kami proses ya',
        context: 'halo tolong diproses',
      );
      expect(verdict.violations, contains('unfilled template slot'));
    });

    test('an invented link is flagged only when none was given', () {
      expect(
        ReplyPolishGate.validate(
          'Cek resinya di https://resi.example.com/track ya kak',
          maxChars: 280,
          allowEmoji: false,
          template: 'Cek resinya di situ ya kak',
          context: 'resi mana kak',
        ).violations,
        contains('invented link'),
      );
      // A URL carried by the template or the incoming message is fine.
      expect(
        ReplyPolishGate.validate(
          'Cek resinya di https://resi.example.com/track ya kak',
          maxChars: 280,
          allowEmoji: false,
          template: 'Cek resinya di https://resi.example.com/track ya kak',
          context: 'resi mana kak',
        ).ok,
        isTrue,
      );
    });

    test('assistant phrasing is flagged', () {
      for (final String text in <String>[
        'As an AI, I cannot process orders',
        'Sebagai AI, saya tidak bisa memproses pesanan',
        'Hope this helps kak',
        'Let me know if you need anything else',
      ]) {
        final PolisherVerdict verdict = ReplyPolishGate.validate(
          text,
          maxChars: 280,
          allowEmoji: false,
          template: 'kami proses ya',
          context: 'tolong diproses',
        );
        expect(
          verdict.violations,
          contains('assistant phrasing'),
          reason: '"$text" must be flagged',
        );
      }
    });

    test('repeating an earlier reply is flagged', () {
      final PolisherVerdict verdict = ReplyPolishGate.validate(
        'Siap kak, sedang kami proses hari ini ya',
        maxChars: 280,
        allowEmoji: false,
        template: 'Siap, sedang kami proses',
        context: 'tolong diproses',
        avoid: <String>['  siap kak,  SEDANG kami proses hari ini YA '],
      );
      expect(verdict.violations, contains('repeats an earlier reply'));
    });
  });

  group('ReplyPolishGate.sanitize', () {
    test('repairs markdown, emoji and slots deterministically', () {
      final String out = ReplyPolishGate.sanitize(
        '**Halo {name}** \u{1F600} cek di https://resi.example.com/x ya `kak`',
        maxChars: 280,
        allowEmoji: false,
      );
      expect(out, isNot(contains('**')));
      expect(out, isNot(contains('{name}')));
      expect(out, isNot(contains('https://')));
      expect(out, isNot(contains('`')));
      expect(out.contains('\u{1F600}'), isFalse);
    });

    test('cuts long output at a word boundary', () {
      final String out = ReplyPolishGate.sanitize(
        'kata ' * 200,
        maxChars: 100,
        allowEmoji: false,
      );
      expect(out.length, lessThanOrEqualTo(100));
      expect(out.endsWith(' '), isFalse);
    });

    test('keeps emoji when they are allowed', () {
      final String out = ReplyPolishGate.sanitize(
        'Siap kak \u{1F600}',
        maxChars: 280,
        allowEmoji: true,
      );
      expect(out.contains('\u{1F600}'), isTrue);
    });
  });

  group('AgentPolisher pipeline', () {
    test('returns the first valid polished reply', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(
          content:
              'Halo kak, makasih sudah kabarin. Pesanan kamu hari ini kami '
              'kirim ya, resinya menyusul nanti siang.',
        ),
      ]);
      final String text = await AgentPolisher(llm: llm)
          .polish(request: request(), config: config());
      expect(text, contains('Halo kak'));
      expect(llm.calls, hasLength(1));
      // The system prompt carries the polish contract, the user prompt
      // carries template + incoming message.
      expect(llm.calls.first.first['content'], contains('social media page'));
      expect(llm.calls.first.last['content'], contains('Template:'));
      expect(llm.calls.first.last['content'], contains('Incoming message:'));
    });

    test(
      'retries once with the violation note when the first output breaks rules',
      () async {
        final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(content: 'Siap kak, kami proses \u{1F600}'), // emoji
          AssistantTurn(content: 'Siap kak, pesananmu kami proses hari ini ya'),
        ]);
        final String text = await AgentPolisher(llm: llm)
            .polish(request: request(), config: config());
        expect(text, 'Siap kak, pesananmu kami proses hari ini ya');
        expect(llm.calls, hasLength(2));
        expect(llm.calls.last.last['content'], contains('violated the rules'));
      },
    );

    test('sanitized second attempt is accepted when it passes', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(
          content: '"**Halo kak**, {name} pesananmu kami proses ya"',
        ),
      ]);
      final String text = await AgentPolisher(llm: llm)
          .polish(request: request(), config: config());
      // preClean strips the wrapping quotes, sanitize drops the slot and
      // markdown — the final re-validate passes.
      expect(text, 'Halo kak, pesananmu kami proses ya');
    });

    test(
      'empty template or context fails fast without calling the LLM',
      () async {
        final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(content: 'x'),
        ]);
        await expectLater(
          AgentPolisher(llm: llm).polish(
            request: const AgentPolishRequest(template: '  ', context: 'hi'),
            config: config(),
          ),
          throwsA(isA<AgentPolishException>()),
        );
        await expectLater(
          AgentPolisher(llm: llm).polish(
            request: const AgentPolishRequest(template: 'hi', context: ''),
            config: config(),
          ),
          throwsA(isA<AgentPolishException>()),
        );
        expect(llm.calls, isEmpty);
      },
    );

    test('the language instruction is baked into the system prompt', () {
      expect(
        ReplyPolishGate.systemPrompt(
          const AgentPolishRequest(template: 'a', context: 'b'),
        ),
        contains('SAME language the incoming message is written'),
      );
      expect(
        ReplyPolishGate.systemPrompt(
          const AgentPolishRequest(template: 'a', context: 'b', language: 'id'),
        ),
        contains('Reply in this language: id'),
      );
    });
  });
}
