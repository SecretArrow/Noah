import 'package:flutter_test/flutter_test.dart';
import 'package:noah/models/cron_job.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/cron_scheduler.dart';
import 'package:noah/services/llm_client.dart';
import 'package:noah/services/telegram_sender.dart';
import 'package:noah/services/tool_executor.dart';

import '../support/test_doubles.dart';

/// Fase 5(a) — the cron agent action resolves its LLM config AT FIRE
/// TIME from the active provider settings (the exact closure
/// cronDispatcherProvider installs in di.dart). When the active preset
/// is the built-in `Local AI`, the headless run must therefore target
/// the on-device llama-server endpoint; switching the active provider
/// must retarget the very next fire — no cron-side provider pinning.
class _CapturingLlm extends LlmClient {
  final List<LlmConfig> configs = <LlmConfig>[];

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    configs.add(config);
    return AssistantTurn(content: 'answer from ${config.baseUrl}');
  }
}

void main() {
  group('cron agent action runs on the ACTIVE provider', () {
    late _CapturingLlm llm;
    late AppSettings settings;

    DefaultCronDispatcher makeDispatcher() => DefaultCronDispatcher(
      llm: llm,
      telegram: TelegramSender(),
      background: RecordingBackgroundRun(),
      executeTool: (
        String name,
        Map<String, dynamic> args, {
        String? sessionId,
        String? browserContext,
      }) async => const ToolResult(ok: true, llmOutput: 'unused'),
      // Mirrors di.dart's cronDispatcherProvider closure verbatim.
      resolveConfig: () => LlmConfig(
        baseUrl: settings.baseUrl,
        apiKey: settings.apiKey,
        model: settings.model,
        engine: settings.engine,
      ),
    );

    CronJob agentJob() => CronJob(
      id: 'agent-1',
      sessionId: 'owner-1',
      name: 'Nightly summary',
      expression: '0 23 * * *',
      action: CronActionKind.agent,
      agentPrompt: 'summarize today',
      createdAtMs: 0,
    );

    setUp(() {
      llm = _CapturingLlm();
      settings = AppSettings(
        providerName: 'Local AI',
        baseUrl: 'http://127.0.0.1:11434/v1',
        model: 'qwen3-4b-instruct',
      );
    });

    test('Local AI preset active -> agent run hits the local server', () async {
      final CronDispatchResult result = await makeDispatcher().dispatch(
        agentJob(),
      );

      expect(result.ok, isTrue);
      expect(result.detail, startsWith('agent done'));
      expect(llm.configs, hasLength(1));
      expect(llm.configs.single.baseUrl, 'http://127.0.0.1:11434/v1');
      expect(llm.configs.single.model, 'qwen3-4b-instruct');
      expect(llm.configs.single.apiKey, isEmpty);
    });

    test('switching the active provider retargets the next fire', () async {
      await makeDispatcher().dispatch(agentJob());
      settings = AppSettings(
        providerName: 'OpenRouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'sk-or-test',
        model: 'z-ai/glm-4.6',
      );
      final CronDispatchResult result = await makeDispatcher().dispatch(
        agentJob(),
      );

      expect(result.ok, isTrue);
      expect(llm.configs, hasLength(2));
      expect(llm.configs.last.baseUrl, 'https://openrouter.ai/api/v1');
      expect(llm.configs.last.model, 'z-ai/glm-4.6');
    });
  });
}
