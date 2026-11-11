import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/chat_store.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

/// v1.40.0 regressions around chat switching:
///  * a message sent while the session's history is still loading must not be
///    dropped when the user switches chats mid-load (the run continues in the
///    background);
///  * `restoreLastChat` must never replace a draft the user already started;
///  * staged composer attachments belong to ONE chat (kept when re-opening
///    the same chat, cleared when switching or deleting).
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_v140_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ChatStore diskStore() =>
      ChatStore(resolveBaseDir: () async => tempDir, offloadIsolate: false);

  Future<ProviderContainer> containerWith(
    LlmClient llm, {
    ChatStore? store,
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        ...testOverrides(
          llm: llm,
          dir: tempDir,
          settings: AppSettings(apiKey: 'k', autoTitle: false),
        ),
        if (store != null) chatStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ChatSummary summary(String id, String title) =>
      ChatSummary(id: id, title: title, updatedAt: DateTime(2025, 3, 1));

  test('a message sent while history loads survives a chat switch', () async {
    final ChatStore seed = diskStore();
    await seed.save(
      id: 'open1',
      title: 'Open chat',
      messages: <ChatMessage>[ChatMessage.user('old message')],
    );

    final Completer<void> gate = Completer<void>();
    final _GatedStore slow = _GatedStore(
      resolveBaseDir: () async => tempDir,
      gateTitle: gate,
    );
    final ProviderContainer container = await containerWith(
      ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'background answer'),
      ]),
      store: slow,
    );
    final ChatController notifier = container.read(
      chatControllerProvider.notifier,
    );

    await notifier.openChat(summary('open1', 'Open chat'));
    expect(container.read(chatControllerProvider).sessionId, 'open1');

    // send() parks in _adoptSession while the stored title is read.
    final Future<void> run = notifier.send('continue please');
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(chatControllerProvider).sessionId,
      'open1',
      reason: 'the message belongs to the chat that was open when it was sent',
    );

    // The user switches to a fresh draft before the load finishes.
    await notifier.newChat();
    gate.complete();
    await run;

    // The UI stays on the draft the user chose…
    final ChatState state = container.read(chatControllerProvider);
    expect(state.sessionId, isNull);
    expect(state.messages, isEmpty);

    // …and the message was NOT dropped: it landed in the chat it was sent to.
    final List<ChatMessage> stored = (await seed.load('open1'))!;
    expect(
      stored.map((ChatMessage m) => m.content),
      containsAll(<String>[
        'old message',
        'continue please',
        'background answer',
      ]),
    );
  });

  test('restoreLastChat never replaces a draft the user started', () async {
    final ChatStore seed = diskStore();
    await seed.save(
      id: 'old',
      title: 'Old chat',
      messages: <ChatMessage>[ChatMessage.user('old message')],
    );

    final Completer<void> gate = Completer<void>();
    final _GatedStore slow = _GatedStore(
      resolveBaseDir: () async => tempDir,
      gateSummaries: gate,
    );
    final ProviderContainer container = await containerWith(
      ScriptedLlmClient(<AssistantTurn>[
        AssistantTurn(content: 'draft answer'),
      ]),
      store: slow,
    );
    final ChatController notifier = container.read(
      chatControllerProvider.notifier,
    );

    // App start: history list is still loading…
    final Future<void> restoring = notifier.restoreLastChat();
    await Future<void>.delayed(Duration.zero);

    // …while the user starts a fresh draft.
    await notifier.send('my own draft');
    gate.complete();
    await restoring;

    final ChatState state = container.read(chatControllerProvider);
    expect(
      state.sessionId,
      isNot('old'),
      reason: 'the late history load must not yank the user away',
    );
    expect(
      state.messages.map((ChatMessage m) => m.content),
      contains('my own draft'),
    );
  });

  test('staged attachments survive re-opening the SAME chat', () async {
    final ChatStore seed = diskStore();
    await seed.save(
      id: 'a',
      title: 'Chat A',
      messages: <ChatMessage>[ChatMessage.user('a')],
    );
    await seed.save(
      id: 'b',
      title: 'Chat B',
      messages: <ChatMessage>[ChatMessage.user('b')],
    );
    final ProviderContainer container = await containerWith(
      ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
    );
    final ChatController notifier = container.read(
      chatControllerProvider.notifier,
    );

    await notifier.openChat(summary('a', 'Chat A'));
    const ChatAttachment staged = ChatAttachment(
      name: 'notes.txt',
      path: 'uploads/notes.txt',
      sizeBytes: 12,
      kind: AttachmentKind.text,
    );
    container.read(pendingAttachmentsProvider.notifier).state =
        <ChatAttachment>[staged];

    // Drawer tap on the row of the chat that is already open.
    await notifier.openChat(summary('a', 'Chat A'));
    expect(
      container.read(pendingAttachmentsProvider),
      <ChatAttachment>[staged],
      reason:
          're-opening the current chat must not silently drop the files '
          'the user staged in its composer',
    );

    // Switching to a different chat does clear them.
    await notifier.openChat(summary('b', 'Chat B'));
    expect(container.read(pendingAttachmentsProvider), isEmpty);
  });

  test('deleting the open chat clears its staged attachments', () async {
    final ChatStore seed = diskStore();
    await seed.save(
      id: 'a',
      title: 'Chat A',
      messages: <ChatMessage>[ChatMessage.user('a')],
    );
    final ProviderContainer container = await containerWith(
      ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
    );
    final ChatController notifier = container.read(
      chatControllerProvider.notifier,
    );

    await notifier.openChat(summary('a', 'Chat A'));
    container
        .read(pendingAttachmentsProvider.notifier)
        .state = <ChatAttachment>[
      const ChatAttachment(
        name: 'notes.txt',
        path: 'uploads/notes.txt',
        sizeBytes: 12,
        kind: AttachmentKind.text,
      ),
    ];

    await notifier.deleteChat('a');

    expect(container.read(pendingAttachmentsProvider), isEmpty);
    final ChatState state = container.read(chatControllerProvider);
    expect(state.sessionId, isNull);
    expect(state.messages, isEmpty);
  });
}

/// ChatStore double with optional gates so a test can interleave a user
/// action with a history load (the real disk reads are far too fast).
class _GatedStore extends ChatStore {
  _GatedStore({
    required super.resolveBaseDir,
    this.gateTitle,
    this.gateSummaries,
  }) : super(offloadIsolate: false);

  final Completer<void>? gateTitle;
  final Completer<void>? gateSummaries;

  @override
  Future<String> loadTitle(String id) async {
    if (gateTitle != null) await gateTitle!.future;
    return super.loadTitle(id);
  }

  @override
  Future<List<ChatSummary>> listSummaries() async {
    if (gateSummaries != null) await gateSummaries!.future;
    return super.listSummaries();
  }
}
