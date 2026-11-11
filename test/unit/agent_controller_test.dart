import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/l10n/app_strings.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/background_service.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

Future<ProviderContainer> _container(
  List<AssistantTurn> turns,
  Directory dir, {
  AppSettings? settings,
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: testOverrides(
      llm: ScriptedLlmClient(turns),
      dir: dir,
      settings: settings ?? AppSettings(apiKey: 'test-key', autoTitle: false),
    ),
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_agent_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('agent loop: executes tool then produces final answer', () async {
    final ProviderContainer container = await _container(<AssistantTurn>[
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 't1',
            name: 'browser_navigate',
            argumentsJson: jsonEncode(<String, dynamic>{
              'url': 'https://example.com',
            }),
          ),
        ],
      ),
      AssistantTurn(content: 'Halaman dibuka: Example Domain'),
    ], tempDir);

    await container
        .read(chatControllerProvider.notifier)
        .send('Buka example.com');
    final ChatState state = container.read(chatControllerProvider);

    expect(state.isRunning, isFalse);
    expect(state.error, isNull);
    expect(state.messages.first.role, Role.user);
    expect(state.messages.first.content, 'Buka example.com');

    final List<ChatMessage> assistant = state.messages
        .where((m) => m.role == Role.assistant)
        .toList();
    expect(assistant, hasLength(2));
    expect(assistant.first.toolCalls.single.status, ToolStatus.success);
    expect(
      assistant.first.toolCalls.single.resultText,
      contains('Example Domain'),
    );
    expect(assistant.last.content, 'Halaman dibuka: Example Domain');
  });

  test('agent loop: write_file then read_file roundtrip', () async {
    final ProviderContainer container = await _container(<AssistantTurn>[
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 'w1',
            name: 'write_file',
            argumentsJson: jsonEncode(<String, dynamic>{
              'path': 'notes/todo.txt',
              'content': 'belajar flutter',
            }),
          ),
        ],
      ),
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 'r1',
            name: 'read_file',
            argumentsJson: jsonEncode(<String, dynamic>{
              'path': 'notes/todo.txt',
            }),
          ),
        ],
      ),
      AssistantTurn(content: 'File tersimpan dan terbaca.'),
    ], tempDir);

    await container
        .read(chatControllerProvider.notifier)
        .send('Simpan catatan');
    final ChatState state = container.read(chatControllerProvider);
    final List<ChatMessage> assistant = state.messages
        .where((m) => m.role == Role.assistant)
        .toList();

    expect(assistant[0].toolCalls.single.status, ToolStatus.success);
    expect(assistant[1].toolCalls.single.status, ToolStatus.success);
    expect(
      assistant[1].toolCalls.single.resultText,
      contains('belajar flutter'),
    );

    // The file lives inside THIS session's isolated workspace now.
    final String sid = container.read(chatControllerProvider).sessionId!;
    final File file = File('${tempDir.path}/sessions/$sid/notes/todo.txt');
    expect(await file.exists(), isTrue);
    expect(await file.readAsString(), 'belajar flutter');
  });

  test('send without API key surfaces a friendly error', () async {
    final ProviderContainer container = await _container(
      <AssistantTurn>[AssistantTurn(content: 'tidak boleh dipanggil')],
      tempDir,
      settings: AppSettings(apiKey: ''),
    );

    await container.read(chatControllerProvider.notifier).send('Halo');
    final ChatState state = container.read(chatControllerProvider);

    expect(state.isRunning, isFalse);
    expect(state.error, contains('API key'));
    expect(state.messages, isEmpty); // rejected before appending anything
  });

  test('maxSteps bounds the number of LLM turns (runUntilDone off)', () async {
    final ScriptedLlmClient scripted = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 'loop',
            name: 'browser_extract_text',
            argumentsJson: '{}',
          ),
        ],
      ),
    ]);
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(
        llm: scripted,
        dir: tempDir,
        settings: AppSettings(
          apiKey: 'k',
          autoTitle: false,
          maxSteps: 2,
          runUntilDone: false,
        ),
      ),
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).send('loop terus');
    expect(scripted.calls, hasLength(2)); // exactly maxSteps turns
    final ChatState state = container.read(chatControllerProvider);
    expect(state.isRunning, isFalse);
    expect(state.error, isNull);
  });

  test(
    'sending to an opened history chat continues it instead of forking',
    () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'first reply'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      // Turn 1 creates and persists session X.
      await container
          .read(chatControllerProvider.notifier)
          .send('first question');
      final String id = container.read(chatControllerProvider).sessionId!;
      expect(id, isNotNull);

      // Reopen it from history (the finished run is no longer tracked).
      await container
          .read(chatControllerProvider.notifier)
          .openChat(
            ChatSummary(
              id: id,
              title: 'first question',
              updatedAt: DateTime.now(),
            ),
          );
      expect(container.read(chatControllerProvider).sessionId, id);

      // Turn 2 must CONTINUE session X — same id, full history on the wire.
      await container
          .read(chatControllerProvider.notifier)
          .send('second question');
      final ChatState state = container.read(chatControllerProvider);
      expect(
        state.sessionId,
        id,
        reason: 'sending into an open chat must not fork a new session',
      );
      expect(
        state.messages.where((m) => m.role == Role.user).map((m) => m.content),
        containsAll(<String>['first question', 'second question']),
      );

      // The LLM wire for the second call replayed the earlier turn.
      final List<Map<String, dynamic>> wire = llm.calls.last;
      final List<String> userTexts = <String>[
        for (final Map<String, dynamic> m in wire)
          if (m['role'] == 'user') m['content'] as String,
      ];
      expect(userTexts, contains('first question'));
      expect(userTexts, contains('second question'));

      // Nothing new was stored: still exactly one conversation file.
      final List<ChatSummary> summaries = await container
          .read(chatStoreProvider)
          .listSummaries();
      expect(summaries, hasLength(1));
      expect(summaries.single.id, id);
    },
  );

  test('restoreLastChat reopens the most recent conversation', () async {
    final ProviderContainer container = await _container(
      <AssistantTurn>[AssistantTurn(content: 'hi there')],
      tempDir,
      settings: AppSettings(apiKey: 'k', autoTitle: false),
    );
    addTearDown(container.dispose);
    final notifier = container.read(chatControllerProvider.notifier);

    await notifier.send('hello world');
    final String id = container.read(chatControllerProvider).sessionId!;
    await notifier.newChat();
    expect(container.read(chatControllerProvider).sessionId, isNull);

    await notifier.restoreLastChat();
    expect(container.read(chatControllerProvider).sessionId, id);
    expect(container.read(chatControllerProvider).messages, isNotEmpty);
  });

  test(
    'restoreLastChat keeps the fresh draft when there is no history',
    () async {
      final ProviderContainer container = await _container(
        <AssistantTurn>[AssistantTurn(content: 'ok')],
        tempDir,
        settings: AppSettings(apiKey: 'k', autoTitle: false),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).restoreLastChat();
      final ChatState state = container.read(chatControllerProvider);
      expect(state.sessionId, isNull);
      expect(state.messages, isEmpty);
    },
  );

  test('runUntilDone ignores maxSteps and works to the final answer', () async {
    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 't1',
            name: 'browser_extract_text',
            argumentsJson: '{}',
          ),
        ],
      ),
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 't2',
            name: 'browser_extract_text',
            argumentsJson: '{}',
          ),
        ],
      ),
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 't3',
            name: 'browser_extract_text',
            argumentsJson: '{}',
          ),
        ],
      ),
      AssistantTurn(content: 'task finished'),
    ]);
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(
        llm: llm,
        dir: tempDir,
        // maxSteps=2 would normally cut the loop after two turns.
        settings: AppSettings(
          apiKey: 'k',
          autoTitle: false,
          maxSteps: 2,
          runUntilDone: true,
        ),
      ),
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).send('long task');
    expect(llm.calls, hasLength(4)); // 3 tool rounds + final answer
    final ChatState state = container.read(chatControllerProvider);
    expect(state.error, isNull);
    expect(state.messages.last.content, 'task finished');
    expect(state.messages.last.toolCalls, isEmpty);
  });

  test('maxSteps cap with runUntilDone=false appends a visible note', () async {
    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(
        content: '',
        toolCalls: <ToolCallRequest>[
          ToolCallRequest(
            id: 'loop',
            name: 'browser_extract_text',
            argumentsJson: '{}',
          ),
        ],
      ),
    ]);
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(
        llm: llm,
        dir: tempDir,
        settings: AppSettings(
          apiKey: 'k',
          autoTitle: false,
          maxSteps: 2,
          runUntilDone: false,
        ),
      ),
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).send('loop terus');
    expect(llm.calls, hasLength(2));
    final ChatState state = container.read(chatControllerProvider);
    expect(state.isRunning, isFalse);
    expect(state.error, isNull);
    // The pause is explained instead of stopping silently.
    expect(
      state.messages.last.content,
      contains(
        appStringsFor('en').maxStepsReachedMarkdown(2).replaceAll('*', ''),
      ),
      reason: 'cap exhaustion must be visible to the user',
    );
  });

  test('openChat on a corrupted session file never crashes', () async {
    final ProviderContainer container = await _container(<AssistantTurn>[
      AssistantTurn(content: 'ok'),
    ], tempDir);
    final Directory chatsDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}chats',
    );
    chatsDir.createSync(recursive: true);
    await File('${chatsDir.path}${Platform.pathSeparator}corrupt.json')
        .writeAsString('{not valid json!!');

    // Must not throw, even though the file cannot be parsed.
    await container
        .read(chatControllerProvider.notifier)
        .openChat(
          ChatSummary(
            id: 'corrupt',
            title: 'Broken',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
    final ChatState state = container.read(chatControllerProvider);
    expect(state.sessionId, 'corrupt');
    expect(state.messages, isEmpty);
  });

  test('openChat storage failure is converted to an error, no crash', () async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
          dir: tempDir,
          settings: AppSettings(apiKey: 'test-key', autoTitle: false),
        ),
        chatStoreProvider.overrideWithValue(ThrowingChatStore()),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(chatControllerProvider.notifier)
        .openChat(
          ChatSummary(
            id: 'any',
            title: 'Any',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
    final ChatState state = container.read(chatControllerProvider);
    expect(state.error, 'Could not open this conversation.');
  });

  test(
    'deleteChat storage failure is converted to an error, no crash',
    () async {
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ...testOverrides(
            llm: ScriptedLlmClient(<AssistantTurn>[
              AssistantTurn(content: 'ok'),
            ]),
            dir: tempDir,
            settings: AppSettings(apiKey: 'test-key', autoTitle: false),
          ),
          chatStoreProvider.overrideWithValue(ThrowingChatStore()),
        ],
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).deleteChat('x');
      final ChatState state = container.read(chatControllerProvider);
      expect(state.error, 'Could not delete this conversation.');
    },
  );

  test('background hold starts and stops around the agent loop', () async {
    final RecordingBackgroundRun background = RecordingBackgroundRun();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: ScriptedLlmClient(<AssistantTurn>[
            AssistantTurn(
              content: '',
              toolCalls: <ToolCallRequest>[
                ToolCallRequest(
                  id: 't1',
                  name: 'browser_navigate',
                  argumentsJson: jsonEncode(<String, dynamic>{
                    'url': 'https://example.com',
                  }),
                ),
              ],
            ),
            AssistantTurn(content: 'done'),
          ]),
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
        backgroundRunServiceProvider.overrideWithValue(background),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).send('go');

    // Started with the localized notification strings…
    expect(
      background.calls.first,
      'start:${appStringsFor('en').notifTitle}'
      '|${appStringsFor('en').notifProcessing}',
    );
    // …received a live per-step update while the tool ran…
    expect(
      background.calls,
      contains(
        'update:${appStringsFor('en').notifStep(1, 'browser_navigate')}',
      ),
    );
    // …and was always released, even on success.
    expect(background.calls.last, 'stop');
    expect(background.isActive, isFalse);

    // v1.42.0: the PER-CHAT notification rode the same lifecycle — started
    // with the chat's own title, live step updates, released with the run.
    final String? sessionId = container.read(chatControllerProvider).sessionId;
    expect(
      background.calls,
      contains(
        'startSession:$sessionId|go|${appStringsFor('en').notifProcessing}',
      ),
    );
    expect(
      background.calls,
      contains(
        'updateSession:$sessionId|'
        '${appStringsFor('en').notifStep(1, 'browser_navigate')}',
      ),
    );
    expect(background.calls, contains('stopSession:$sessionId'));
    expect(
      background.calls.indexOf('stopSession:$sessionId'),
      lessThan(background.calls.lastIndexOf('stop')),
    );
    expect(background.activeSessions, isEmpty);
  });

  test('background hold is released even when the LLM throws', () async {
    final RecordingBackgroundRun background = RecordingBackgroundRun();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: _ThrowingLlmClient(),
          dir: tempDir,
          // Auto-retry OFF: this test pins the RAW error path (no retries).
          settings: AppSettings(
            apiKey: 'k',
            autoTitle: false,
            autoRetryEnabled: false,
          ),
        ),
        backgroundRunServiceProvider.overrideWithValue(background),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).send('boom');

    final ChatState state = container.read(chatControllerProvider);
    expect(state.isRunning, isFalse);
    expect(state.error, isNotNull);
    expect(background.calls.first, startsWith('start:'));
    expect(background.calls.last, 'stop');
  });

  test('stop during streaming aborts the turn and marks it stopped', () async {
    final RecordingBackgroundRun background = RecordingBackgroundRun();
    late final ProviderContainer container;
    final ScriptedLlmClient llm = ScriptedLlmClient(
      <AssistantTurn>[AssistantTurn(content: 'a long answer')],
      // Stop the run as soon as the first token arrives.
      onFirstDelta: () =>
          container.read(chatControllerProvider.notifier).stop(),
    );
    container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
        backgroundRunServiceProvider.overrideWithValue(background),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).send('go');

    // The abort cut the stream short: no second LLM call was made and the
    // partial answer is kept with the stopped marker.
    expect(llm.calls, hasLength(1));
    final ChatState state = container.read(chatControllerProvider);
    expect(state.isRunning, isFalse);
    expect(state.messages.last.role, Role.assistant);
    expect(state.messages.last.content, contains('a'));
    expect(state.messages.last.content, contains('_(stopped)_'));
    expect(state.messages.last.isStreaming, isFalse);
    // The background hold was still released on the abort path.
    expect(background.calls.last, 'stop');
  });

  test('stop between steps prevents the next LLM call', () async {
    late final ProviderContainer container;
    final ScriptedLlmClient llm = ScriptedLlmClient(
      <AssistantTurn>[
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 't1',
              name: 'browser_navigate',
              argumentsJson: jsonEncode(<String, dynamic>{
                'url': 'https://example.com',
              }),
            ),
          ],
        ),
        AssistantTurn(content: 'should never be reached'),
      ],
      // Stop the run as soon as the tool-call turn is handed back.
      onTurnComplete: () =>
          container.read(chatControllerProvider.notifier).stop(),
    );
    container = ProviderContainer(
      overrides: testOverrides(
        llm: llm,
        dir: tempDir,
        settings: AppSettings(apiKey: 'k', autoTitle: false),
      ),
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).send('go');

    // The loop exited before the second turn and before executing the
    // requested tool — the streaming placeholder is marked stopped.
    expect(llm.calls, hasLength(1));
    final ChatState state = container.read(chatControllerProvider);
    expect(state.isRunning, isFalse);
    expect(state.messages.last.role, Role.assistant);
    expect(state.messages.last.content, '_(stopped)_');
    expect(state.messages.last.isStreaming, isFalse);
  });

  test('runInBackground=false never touches the background service', () async {
    final RecordingBackgroundRun background = RecordingBackgroundRun();
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
          dir: tempDir,
          settings: AppSettings(
            apiKey: 'k',
            autoTitle: false,
            runInBackground: false,
          ),
        ),
        backgroundRunServiceProvider.overrideWithValue(background),
      ],
    );
    addTearDown(container.dispose);

    await container.read(chatControllerProvider.notifier).send('plain');
    expect(background.calls, isEmpty);
  });

  test(
    'enabled context entries are injected into the system message',
    () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'ok'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
          contexts: <ContextEntry>[
            const ContextEntry(
              id: 'c1',
              name: 'House rules',
              content: 'Always be brief.',
              enabled: true,
            ),
            const ContextEntry(
              id: 'c2',
              name: 'Disabled',
              content: 'Never applied.',
              enabled: false,
            ),
          ],
        ),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('hi');
      final List<Map<String, dynamic>> wire = llm.calls.first;
      expect(wire.first['role'], 'system');
      expect(wire.first['content'], contains('Always be brief.'));
      expect(wire.first['content'], contains('# Context: House rules'));
      expect(wire.first['content'], isNot(contains('Never applied.')));
    },
  );

  test('text attachments travel inline in the user wire message', () async {
    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(content: 'parsed'),
    ]);
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(
        llm: llm,
        dir: tempDir,
        settings: AppSettings(apiKey: 'k', autoTitle: false),
      ),
    );
    addTearDown(container.dispose);

    final File dataFile = File('${tempDir.path}/numbers.csv');
    await dataFile.writeAsString('a,b\n1,2');

    await container
        .read(chatControllerProvider.notifier)
        .send(
          'analyze this',
          attachments: <ChatAttachment>[
            ChatAttachment(
              name: 'numbers.csv',
              path: dataFile.path,
              sizeBytes: 8,
              kind: AttachmentKind.text,
            ),
          ],
        );
    final Map<String, dynamic> userWire = llm.calls.first.firstWhere(
      (m) => m['role'] == 'user',
    );
    expect(userWire['content'], contains('analyze this'));
    expect(userWire['content'], contains('[Attached file: numbers.csv]'));
    expect(userWire['content'], contains('a,b\n1,2'));
  });

  test('image attachments become OpenAI vision content parts', () async {
    final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
      AssistantTurn(content: 'nice picture'),
    ]);
    final ProviderContainer container = ProviderContainer(
      overrides: testOverrides(
        llm: llm,
        dir: tempDir,
        settings: AppSettings(apiKey: 'k', autoTitle: false),
      ),
    );
    addTearDown(container.dispose);

    final File image = File('${tempDir.path}/tiny.png');
    await image.writeAsBytes(base64Decode(tinyPngBase64));

    await container
        .read(chatControllerProvider.notifier)
        .send(
          'what is this?',
          attachments: <ChatAttachment>[
            ChatAttachment(
              name: 'tiny.png',
              path: image.path,
              sizeBytes: 100,
              kind: AttachmentKind.image,
            ),
          ],
        );
    final Map<String, dynamic> userWire = llm.calls.first.firstWhere(
      (m) => m['role'] == 'user',
    );
    final List<dynamic> parts = userWire['content'] as List<dynamic>;
    expect(parts.first['type'], 'text');
    expect(parts.first['text'], contains('what is this?'));
    expect(parts.last['type'], 'image_url');
    expect(
      (parts.last['image_url'] as Map<String, dynamic>)['url'],
      startsWith('data:image/png;base64,'),
    );
  });

  test(
    'sessions run in parallel and switching never interrupts them',
    () async {
      // Gate each LLM turn behind a completer so we control run timing.
      final List<Completer<AssistantTurn>> gates =
          List<Completer<AssistantTurn>>.generate(
            4,
            (_) => Completer<AssistantTurn>(),
          );
      int turn = 0;
      final _GatedLlmClient llm = _GatedLlmClient(gates, () => turn++);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      // Session A starts and blocks mid-run.
      final Future<void> runA = container
          .read(chatControllerProvider.notifier)
          .send('task A');
      await Future<void>.delayed(Duration.zero);
      final String? idA = container.read(chatControllerProvider).sessionId;
      expect(idA, isNotNull);
      expect(container.read(chatControllerProvider).isRunning, isTrue);
      expect(container.read(runningSessionsProvider), contains(idA));

      // Starting a NEW session while A runs must be possible.
      await container.read(chatControllerProvider.notifier).newChat();
      final Future<void> runB = container
          .read(chatControllerProvider.notifier)
          .send('task B');
      await Future<void>.delayed(Duration.zero);
      final String? idB = container.read(chatControllerProvider).sessionId;
      expect(idB, isNot(idA));
      expect(
        container.read(runningSessionsProvider),
        containsAll(<String?>[idA, idB]),
      );

      // Finish A, then B.
      gates[0].complete(AssistantTurn(content: 'A done'));
      await runA;
      expect(
        container.read(chatControllerProvider).sessionId,
        idB,
        reason: 'finishing a background run must not switch the screen',
      );
      gates[1].complete(AssistantTurn(content: 'B done'));
      await runB;
      expect(container.read(runningSessionsProvider), isEmpty);

      // Both conversations were persisted independently.
      final List<ChatSummary> summaries = await container
          .read(chatStoreProvider)
          .listSummaries();
      expect(
        summaries.map((s) => s.title),
        containsAll(<String>['task A', 'task B']),
      );
    },
  );

  test('renameChat updates the stored title', () async {
    final ProviderContainer container = await _container(<AssistantTurn>[
      AssistantTurn(content: 'ok'),
    ], tempDir);
    await container.read(chatControllerProvider.notifier).send('hello');
    final String id = container.read(chatControllerProvider).sessionId!;
    await container
        .read(chatControllerProvider.notifier)
        .renameChat(id, 'Renamed');
    final List<ChatSummary> summaries = await container
        .read(chatStoreProvider)
        .listSummaries();
    expect(summaries.single.title, 'Renamed');
  });

  test(
    'deleting a running session stops it and skips the final persist',
    () async {
      final List<Completer<AssistantTurn>> gates =
          List<Completer<AssistantTurn>>.generate(
            2,
            (_) => Completer<AssistantTurn>(),
          );
      int turn = 0;
      final _GatedLlmClient llm = _GatedLlmClient(gates, () => turn++);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      final Future<void> run = container
          .read(chatControllerProvider.notifier)
          .send('doomed');
      await Future<void>.delayed(Duration.zero);
      final String id = container.read(chatControllerProvider).sessionId!;

      await container.read(chatControllerProvider.notifier).deleteChat(id);
      gates[0].complete(AssistantTurn(content: 'too late'));
      await run;

      expect(
        await container.read(chatStoreProvider).load(id),
        isNull,
        reason: 'a deleted session must not be resurrected by its own run',
      );
      expect(container.read(runningSessionsProvider), isEmpty);
    },
  );

  group('plan-first (todos)', () {
    List<String> userTexts(List<Map<String, dynamic>> wire) => <String>[
      for (final Map<String, dynamic> m in wire)
        if (m['role'] == 'user') m['content'] as String,
    ];

    test(
      'premature final answer is nudged until every todo is completed',
      () async {
        final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
          // 1. The model writes the plan.
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'p1',
                name: 'todo_write',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'todos': <dynamic>[
                    <String, dynamic>{
                      'content': 'research topic',
                      'status': 'in_progress',
                    },
                    <String, dynamic>{
                      'content': 'write report',
                      'status': 'pending',
                    },
                  ],
                }),
              ),
            ],
          ),
          // 2. Premature "final answer" while the plan is incomplete.
          AssistantTurn(content: 'partially done…'),
          // 3. After the nudge it finishes the remaining todo.
          AssistantTurn(
            content: '',
            toolCalls: <ToolCallRequest>[
              ToolCallRequest(
                id: 'p2',
                name: 'todo_write',
                argumentsJson: jsonEncode(<String, dynamic>{
                  'todos': <dynamic>[
                    <String, dynamic>{
                      'content': 'research topic',
                      'status': 'completed',
                    },
                    <String, dynamic>{
                      'content': 'write report',
                      'status': 'completed',
                    },
                  ],
                }),
              ),
            ],
          ),
          // 4. Real final answer.
          AssistantTurn(content: 'all done'),
        ]);
        final ProviderContainer container = ProviderContainer(
          overrides: testOverrides(
            llm: llm,
            dir: tempDir,
            settings: AppSettings(apiKey: 'k', autoTitle: false),
          ),
        );
        addTearDown(container.dispose);

        await container.read(chatControllerProvider.notifier).send('do a task');
        expect(llm.calls, hasLength(4)); // plan, premature, continue, final

        // The wire of the continuation call contains the wire-only nudge.
        final List<String> nudged = userTexts(llm.calls[2]);
        expect(
          nudged.any((String t) => t.contains('plan is not finished')),
          isTrue,
          reason: 'an incomplete plan must keep the agent working',
        );
        expect(
          nudged.any(
            (String t) => t.contains('- [in_progress] research topic'),
          ),
          isTrue,
        );
        expect(
          nudged.any((String t) => t.contains('- [pending] write report')),
          isTrue,
        );

        // The nudge is wire-only: the visible transcript shows exactly one
        // user message and ends with the real final answer.
        final ChatState state = container.read(chatControllerProvider);
        expect(
          state.messages.where((ChatMessage m) => m.role == Role.user),
          hasLength(1),
        );
        expect(state.messages.last.content, 'all done');
        expect(state.isRunning, isFalse);
        expect(state.error, isNull);

        // The final plan is mirrored into the UI state for the live
        // show/hide plan panel (here: everything completed).
        expect(state.todos, hasLength(2));
        expect(
          state.todos.every((TodoItem t) => t.status == TodoStatus.completed),
          isTrue,
        );

        // Continuation semantics intact: still exactly one stored chat.
        final List<ChatSummary> summaries = await container
            .read(chatStoreProvider)
            .listSummaries();
        expect(summaries, hasLength(1));
      },
    );

    test('a completed plan does not trigger the nudge', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 'p1',
              name: 'todo_write',
              argumentsJson: jsonEncode(<String, dynamic>{
                'todos': <dynamic>[
                  <String, dynamic>{
                    'content': 'only step',
                    'status': 'completed',
                  },
                ],
              }),
            ),
          ],
        ),
        AssistantTurn(content: 'done'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('quick task');
      expect(llm.calls, hasLength(2)); // plan + final answer, no nudge round
      expect(
        container.read(chatControllerProvider).messages.last.content,
        'done',
      );
    });

    test('planFirst=false + runUntilDone=false: no todo tool, no addendum, no nudge', () async {
      // v1.48.1: the end-of-turn nudge fires when agentMode is on and
      // EITHER runUntilDone or planFirst is on. This test turns BOTH
      // off, so a premature answer is still accepted without a nudge.
      // (runUntilDone=true + planFirst=false now DOES nudge — see
      // plan_sync_test.dart.)
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(
          content: '',
          toolCalls: <ToolCallRequest>[
            ToolCallRequest(
              id: 'p1',
              name: 'todo_write',
              argumentsJson: jsonEncode(<String, dynamic>{
                'todos': <dynamic>[
                  <String, dynamic>{
                    'content': 'never finished',
                    'status': 'pending',
                  },
                ],
              }),
            ),
          ],
        ),
        AssistantTurn(content: 'stopping anyway'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(
            apiKey: 'k',
            autoTitle: false,
            planFirst: false,
            runUntilDone: false,
          ),
        ),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('task');
      expect(llm.calls, hasLength(2)); // premature answer accepted

      final List<Map<String, dynamic>>? tools = llm.toolSets.first;
      expect(tools, isNotNull);
      expect(
        tools!.where(
          (Map<String, dynamic> t) => t['function']['name'] == 'todo_write',
        ),
        isEmpty,
        reason: 'the planning tool must not be advertised',
      );
      expect(
        llm.calls.first.first['content'] as String,
        isNot(contains('Task planning (todos)')),
      );
      expect(
        container.read(chatControllerProvider).messages.last.content,
        'stopping anyway',
      );
    });

    test(
      'planFirst=true: todo_write is the first tool + prompt addendum',
      () async {
        final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
          AssistantTurn(content: 'ok'),
        ]);
        final ProviderContainer container = ProviderContainer(
          overrides: testOverrides(
            llm: llm,
            dir: tempDir,
            settings: AppSettings(apiKey: 'k', autoTitle: false),
          ),
        );
        addTearDown(container.dispose);

        await container.read(chatControllerProvider.notifier).send('hello');
        final List<Map<String, dynamic>>? tools = llm.toolSets.first;
        final List<String> names = <String>[
          for (final Map<String, dynamic> t in tools!)
            t['function']['name'] as String,
        ];
        expect(names.first, 'todo_write');
        expect(names, contains('browser_navigate'));
        expect(
          llm.calls.first.first['content'] as String,
          contains('Task planning (todos)'),
        );
      },
    );
  });

  group('binary attachments expose their documents path', () {
    test('zip attachments advertise the uploads path + unzip_file hint on the wire', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'extracted'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      // Mimic the composer: the picked file is copied into uploads/.
      final Directory uploads = Directory(
        '${tempDir.path}${Platform.pathSeparator}uploads',
      );
      await uploads.create(recursive: true);
      final File zip = File(
        '${uploads.path}${Platform.pathSeparator}1_project.zip',
      );
      await zip.writeAsBytes(<int>[1, 2, 3, 4]);

      await container
          .read(chatControllerProvider.notifier)
          .send(
            'run the JS project inside',
            attachments: <ChatAttachment>[
              ChatAttachment(
                name: 'project.zip',
                path: zip.path,
                sizeBytes: 4,
                kind: AttachmentKind.other,
              ),
            ],
          );

      final Map<String, dynamic> userWire = llm.calls.first.firstWhere(
        (m) => m['role'] == 'user',
      );
      final String content = userWire['content'] as String;
      expect(content, contains('[Attached file: project.zip'));
      // The documents-relative path + how-to hint reach the model.
      expect(content, contains('uploads/1_project.zip'));
      expect(content, contains('unzip_file'));
      expect(content, contains('node_run'));
    });

    test('non-zip binaries get the generic processing hint', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'noted'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      final File bin = File('${tempDir.path}/data.bin');
      await bin.writeAsBytes(<int>[9, 9]);

      await container
          .read(chatControllerProvider.notifier)
          .send(
            'inspect this',
            attachments: <ChatAttachment>[
              ChatAttachment(
                name: 'data.bin',
                path: bin.path,
                sizeBytes: 2,
                kind: AttachmentKind.other,
              ),
            ],
          );

      final Map<String, dynamic> userWire = llm.calls.first.firstWhere(
        (m) => m['role'] == 'user',
      );
      final String content = userWire['content'] as String;
      expect(content, contains('data.bin'));
      expect(content, contains('node_run'));
      expect(content, isNot(contains('unzip_file with this path')));
    });

    test('agent tool list includes zip_file and unzip_file', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'ok'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('hello');
      final List<Map<String, dynamic>>? tools = llm.toolSets.first;
      final List<String> names = <String>[
        for (final Map<String, dynamic> t in tools!)
          t['function']['name'] as String,
      ];
      expect(names, containsAll(<String>['zip_file', 'unzip_file']));
    });
  });

  group('edit user message (v1.15.0)', () {
    test('truncates history after the message and re-runs the loop', () async {
      final File dataFile = File('${tempDir.path}/numbers.csv');
      await dataFile.writeAsString('a,b\n1,2');
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'first answer'),
        AssistantTurn(content: 'EDITED ANSWER MARKER'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatControllerProvider.notifier);

      await notifier.send(
        'first question',
        attachments: <ChatAttachment>[
          ChatAttachment(
            name: 'numbers.csv',
            path: dataFile.path,
            sizeBytes: 8,
            kind: AttachmentKind.text,
          ),
        ],
      );
      final String id = container.read(chatControllerProvider).sessionId!;
      expect(llm.calls, hasLength(1));

      final bool ok = await notifier.editUserMessage(id, 0, 'edited question');
      expect(ok, isTrue);
      final ChatState state = container.read(chatControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.error, isNull);
      expect(state.messages, hasLength(2));
      expect(state.messages.first.content, 'edited question');
      // The edited message keeps its attachments.
      expect(state.messages.first.attachments.single.name, 'numbers.csv');
      expect(state.messages.last.content, 'EDITED ANSWER MARKER');

      // The replay wire carried ONLY the truncated transcript.
      expect(llm.calls, hasLength(2));
      final List<String> userTexts = <String>[
        for (final Map<String, dynamic> m in llm.calls.last)
          if (m['role'] == 'user')
            (m['content'] as String).contains('edited question')
                ? 'edited question'
                : 'other',
      ];
      expect(userTexts, contains('edited question'));
      expect(
        llm.calls.last.map((m) => m['content']).join('\n'),
        isNot(contains('first answer')),
      );
      expect(
        llm.calls.last.map((m) => m['content']).join('\n'),
        contains('a,b\n1,2'),
        reason: 'the attachment body must reach the model again',
      );

      // Persisted messages reflect the truncated transcript.
      final List<ChatMessage>? stored = await container
          .read(chatStoreProvider)
          .load(id);
      expect(stored, hasLength(2));
      expect(stored!.first.content, 'edited question');
      expect(stored.last.content, 'EDITED ANSWER MARKER');
    });

    test('works on a session freshly opened from history', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'old answer'),
        AssistantTurn(content: 'new answer'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatControllerProvider.notifier);

      await notifier.send('question one');
      final String id = container.read(chatControllerProvider).sessionId!;
      await notifier.newChat();
      await notifier.openChat(
        ChatSummary(id: id, title: 'question one', updatedAt: DateTime.now()),
      );
      // No live run exists yet: the edit must materialize from disk first.
      final bool ok = await notifier.editUserMessage(id, 0, 'question edited');
      expect(ok, isTrue);
      final ChatState state = container.read(chatControllerProvider);
      expect(state.sessionId, id, reason: 'editing must not fork a new chat');
      expect(state.messages.first.content, 'question edited');
      expect(state.messages.last.content, 'new answer');
      expect(llm.calls, hasLength(2));
    });

    test('guards: wrong role, unknown session, bad index', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'answer'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatControllerProvider.notifier);

      expect(await notifier.editUserMessage('missing', 0, 'x'), isFalse);
      await notifier.send('hello');
      final String id = container.read(chatControllerProvider).sessionId!;
      // Index 1 is the assistant answer — only user messages are editable.
      expect(await notifier.editUserMessage(id, 1, 'x'), isFalse);
      expect(await notifier.editUserMessage(id, 99, 'x'), isFalse);
      expect(await notifier.editUserMessage(id, 0, '   '), isFalse);
      expect(llm.calls, hasLength(1), reason: 'rejected edits must not re-run');
    });

    test('returns false while the session is running', () async {
      final List<Completer<AssistantTurn>> gates =
          List<Completer<AssistantTurn>>.generate(
            2,
            (_) => Completer<AssistantTurn>(),
          );
      int turn = 0;
      final _GatedLlmClient llm = _GatedLlmClient(gates, () => turn++);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatControllerProvider.notifier);

      final Future<void> run = notifier.send('busy');
      await Future<void>.delayed(Duration.zero);
      final String id = container.read(chatControllerProvider).sessionId!;
      expect(container.read(chatControllerProvider).isRunning, isTrue);

      expect(await notifier.editUserMessage(id, 0, 'nope'), isFalse);
      expect(await notifier.regenerate(id), isFalse);

      gates[0].complete(AssistantTurn(content: 'done'));
      await run;
      gates[1].complete(AssistantTurn(content: 'after-edit'));
      expect(await notifier.editUserMessage(id, 0, 'after'), isTrue);
    });
  });

  group('regenerate (v1.15.0)', () {
    test('drops only the trailing assistant answer and re-runs', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'first answer'),
        AssistantTurn(content: 'REGENERATED MARKER'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatControllerProvider.notifier);

      await notifier.send('the question');
      final String id = container.read(chatControllerProvider).sessionId!;

      final bool ok = await notifier.regenerate(id);
      expect(ok, isTrue);
      final ChatState state = container.read(chatControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.error, isNull);
      // Same user message, brand-new assistant answer.
      expect(state.messages, hasLength(2));
      expect(state.messages.first.role, Role.user);
      expect(state.messages.first.content, 'the question');
      expect(state.messages.last.content, 'REGENERATED MARKER');

      // The replay wire contained the kept user message, not the old answer.
      final List<Map<String, dynamic>> wire = llm.calls.last;
      expect(
        wire.map((m) => m['content']).join('\n'),
        isNot(contains('first answer')),
      );

      final List<ChatMessage>? stored = await container
          .read(chatStoreProvider)
          .load(id);
      expect(stored!.last.content, 'REGENERATED MARKER');
      expect(stored.first.content, 'the question');
    });

    test('returns false without a user message or unknown session', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'answer'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatControllerProvider.notifier);

      expect(await notifier.regenerate('missing'), isFalse);
      await notifier.send('hello');
      expect(
        await notifier.regenerate(
          container.read(chatControllerProvider).sessionId!,
        ),
        isTrue,
      );
      // After regenerating there is still a user message, but a session
      // without any user message can never regenerate: craft one via a
      // stored file with only an assistant message.
      final String id = 'assistant-only';
      await container
          .read(chatStoreProvider)
          .save(
            id: id,
            title: 'lonely',
            messages: <ChatMessage>[ChatMessage.assistant('hi')],
          );
      await notifier.newChat();
      await notifier.openChat(
        ChatSummary(id: id, title: 'lonely', updatedAt: DateTime.now()),
      );
      expect(await notifier.regenerate(id), isFalse);
    });
  });

  group('auto-title (v1.15.0)', () {
    test('renames the session with the sanitized model title', () async {
      final _AutoTitleLlmClient llm = _AutoTitleLlmClient(
        chatTurn: AssistantTurn(content: 'a good reply'),
        titleContent: ' "Judul Bagus" ',
      );
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          // autoTitle defaults to true — nothing to enable.
          settings: AppSettings(apiKey: 'k'),
        ),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('halo agent');
      final ChatState state = container.read(chatControllerProvider);
      expect(state.title, 'Judul Bagus');
      expect(llm.calls, hasLength(2), reason: 'chat turn + title turn');
      // The title call is a plain two-message request without tools.
      expect(llm.toolSets.last, isNull);
      expect(llm.calls.last, hasLength(2));
      expect(llm.calls.last.first['role'], 'system');
      expect(llm.calls.last.last['content'], contains('halo agent'));
      expect(llm.calls.last.last['content'], contains('a good reply'));

      final List<ChatSummary> summaries = await container
          .read(chatStoreProvider)
          .listSummaries();
      expect(summaries.single.title, 'Judul Bagus');
    });

    test('disabled setting makes exactly one LLM call', () async {
      final ScriptedLlmClient llm = ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'answer'),
      ]);
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('hello');
      expect(llm.calls, hasLength(1));
      expect(container.read(chatControllerProvider).title, 'hello');
    });

    test(
      'a failing title call keeps the old title, no error surfaced',
      () async {
        final _AutoTitleLlmClient llm = _AutoTitleLlmClient(
          chatTurn: AssistantTurn(content: 'a good reply'),
          titleError: 'provider exploded',
        );
        final ProviderContainer container = ProviderContainer(
          overrides: testOverrides(
            llm: llm,
            dir: tempDir,
            settings: AppSettings(apiKey: 'k'),
          ),
        );
        addTearDown(container.dispose);

        await container
            .read(chatControllerProvider.notifier)
            .send('halo agent');
        final ChatState state = container.read(chatControllerProvider);
        expect(state.error, isNull, reason: 'title failure must stay silent');
        expect(state.title, 'halo agent');
        final List<ChatSummary> summaries = await container
            .read(chatStoreProvider)
            .listSummaries();
        expect(summaries.single.title, 'halo agent');
      },
    );

    test('a manual rename blocks the automatic title', () async {
      final _AutoTitleLlmClient llm = _AutoTitleLlmClient(
        chatTurn: AssistantTurn(content: 'a good reply'),
        titleContent: 'Model Title',
      );
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k'),
        ),
      );
      addTearDown(container.dispose);
      final notifier = container.read(chatControllerProvider.notifier);

      // First turn: the title model returns '' → the prompt prefix stays.
      llm.titleContent = '';
      await notifier.send('halo agent');
      expect(container.read(chatControllerProvider).title, 'halo agent');

      // Manual rename is authoritative…
      await notifier.renameChat(
        container.read(chatControllerProvider).sessionId!,
        'Manual Title',
      );
      // …and reopening (like the drawer does) picks the stored name up, so
      // the second turn never triggers a retitle.
      final List<ChatSummary> renamed = await container.read(
        chatListProvider.future,
      );
      await notifier.newChat();
      await notifier.openChat(renamed.first);
      llm.titleContent = 'Model Title';
      await notifier.send('second question');
      final List<ChatSummary> summaries = await container
          .read(chatStoreProvider)
          .listSummaries();
      expect(summaries.single.title, 'Manual Title');
      expect(summaries, hasLength(1));
    });
  });

  group('done notification (v1.18.0)', () {
    test('fires when the run ends while the app is backgrounded', () async {
      final RecordingBackgroundRun background = RecordingBackgroundRun();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ...testOverrides(
            llm: ScriptedLlmClient(<AssistantTurn>[
              AssistantTurn(content: 'ok'),
            ]),
            dir: tempDir,
            settings: AppSettings(apiKey: 'k', autoTitle: false),
          ),
          backgroundRunServiceProvider.overrideWithValue(background),
          appInForegroundProvider.overrideWith((Ref ref) => false),
        ],
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('go');

      expect(background.doneNotifications, hasLength(1));
      final List<String> parts = background.doneNotifications.single.split('|');
      expect(parts.first, appStringsFor('en').notifDoneTitle);
      expect(
        parts.last.length,
        greaterThanOrEqualTo(10),
        reason: 'session id is attached for the tap deep link',
      );
    });

    test('stays silent while the app is in the foreground', () async {
      final RecordingBackgroundRun background = RecordingBackgroundRun();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ...testOverrides(
            llm: ScriptedLlmClient(<AssistantTurn>[
              AssistantTurn(content: 'ok'),
            ]),
            dir: tempDir,
            settings: AppSettings(apiKey: 'k', autoTitle: false),
          ),
          backgroundRunServiceProvider.overrideWithValue(background),
        ],
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('go');

      expect(background.doneNotifications, isEmpty);
    });

    test('stays silent when the user turned notifications off', () async {
      final RecordingBackgroundRun background = RecordingBackgroundRun();
      final ProviderContainer container = ProviderContainer(
        overrides: <Override>[
          ...testOverrides(
            llm: ScriptedLlmClient(<AssistantTurn>[
              AssistantTurn(content: 'ok'),
            ]),
            dir: tempDir,
            settings: AppSettings(
              apiKey: 'k',
              autoTitle: false,
              notifyOnDone: false,
            ),
          ),
          backgroundRunServiceProvider.overrideWithValue(background),
          appInForegroundProvider.overrideWith((Ref ref) => false),
        ],
      );
      addTearDown(container.dispose);

      await container.read(chatControllerProvider.notifier).send('go');

      expect(background.doneNotifications, isEmpty);
    });
  });

  group('persist-at-start (v1.28.0)', () {
    test('a brand-new session appears in the chat list while its run is still '
        'in flight', () async {
      final List<Completer<AssistantTurn>> gates = <Completer<AssistantTurn>>[
        Completer<AssistantTurn>(),
      ];
      var calls = 0;
      final ProviderContainer container = ProviderContainer(
        overrides: testOverrides(
          llm: _GatedLlmClient(gates, () => calls++),
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
      );
      addTearDown(container.dispose);

      final ChatController controller = container.read(
        chatControllerProvider.notifier,
      );
      // Do NOT await: the run must be in flight while we inspect the list.
      final Future<void> inFlight = controller.send('chat baru B');
      // Let the loop reach the persist-at-start point.
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final List<ChatSummary> summaries = await container
          .read(chatStoreProvider)
          .listSummaries();
      expect(summaries, hasLength(1));
      expect(summaries.single.title, 'chat baru B');

      // Badge state: the new session is registered as running.
      expect(
        container.read(runningSessionsProvider).contains(summaries.single.id),
        isTrue,
      );

      // Finish the run; everything lands normally afterwards.
      gates.single.complete(AssistantTurn(content: 'selesai'));
      await inFlight;
      expect(container.read(chatControllerProvider).isRunning, isFalse);
    });
  });
}

/// LLM test double whose turns are gated behind completers for parallel-run tests.
class _GatedLlmClient implements LlmClient {
  _GatedLlmClient(this.gates, this.nextTurn);

  final List<Completer<AssistantTurn>> gates;
  final int Function() nextTurn;

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) => gates[nextTurn() % gates.length].future;
}

/// LLM test double whose complete() always throws — proves the controller
/// releases the background hold on the error path.
class _ThrowingLlmClient implements LlmClient {
  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async => throw const SocketException('provider unreachable');
}

/// LLM test double for the auto-title tests: the agent chat (tools != null) gets
/// [chatTurn]; the tool-less title request gets [titleContent] or throws.
class _AutoTitleLlmClient implements LlmClient {
  _AutoTitleLlmClient({
    required this.chatTurn,
    this.titleContent = '',
    this.titleError,
  });

  AssistantTurn chatTurn;
  String titleContent;
  String? titleError;

  final List<List<Map<String, dynamic>>> calls = <List<Map<String, dynamic>>>[];
  final List<List<Map<String, dynamic>>?> toolSets =
      <List<Map<String, dynamic>>?>[];

  @override
  Future<AssistantTurn> complete({
    required LlmConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    void Function(String delta)? onDelta,
    bool Function()? shouldAbort,
    Object? cancelKey,
  }) async {
    calls.add(messages);
    toolSets.add(tools);
    if (tools == null) {
      if (titleError != null) throw LlmException(titleError!);
      return AssistantTurn(content: titleContent);
    }
    return chatTurn;
  }
}
