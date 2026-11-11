import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/chat_store.dart' show ChatStore, SessionBundle;
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

/// v1.49.0 (wave-2) — per-chat ACTIVE SKILLS: the composer skill sheet's
/// selection lives on [ChatState.activeSkills], is stored per chat in the
/// transcript JSON, and NEVER leaks between chats.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_skills_chat');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ProviderContainer container() {
    final ProviderContainer c = ProviderContainer(
      overrides: testOverrides(
        llm: ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
        dir: tempDir,
        settings: AppSettings(apiKey: 'k', autoTitle: false),
      ),
    );
    addTearDown(c.dispose);
    return c;
  }

  group('ChatState.activeSkills (defaults + copyWith)', () {
    test('defaults to an empty list and survives copyWith untouched', () {
      const ChatState state = ChatState();
      expect(state.activeSkills, isEmpty);
      final ChatState edited = state.copyWith(title: 'x');
      expect(edited.activeSkills, isEmpty);
      expect(identical(edited.activeSkills, state.activeSkills), isTrue);
    });

    test('copyWith replaces the selection', () {
      const ChatState state = ChatState();
      final ChatState pinned = state.copyWith(
        activeSkills: <String>['demo-skill'],
      );
      expect(pinned.activeSkills, <String>['demo-skill']);
      // A later copyWith without the field keeps the pinned selection.
      expect(pinned.copyWith(isRunning: true).activeSkills, <String>[
        'demo-skill',
      ]);
      // Applying another selection REPLACES it (apply = replace, the
      // sheet sends the full list every time).
      expect(pinned.copyWith(activeSkills: <String>[]).activeSkills, isEmpty);
    });
  });

  group('setActiveSkills on the controller', () {
    test('fresh draft: the selection lands on the draft state', () async {
      final ProviderContainer c = container();
      final ChatController controller = c.read(chatControllerProvider.notifier);
      expect(c.read(chatControllerProvider).sessionId, isNull);
      await controller.setActiveSkills(<String>['demo-skill']);
      expect(c.read(chatControllerProvider).activeSkills, <String>[
        'demo-skill',
      ]);
      // Re-applying the same selection is a no-op, and the input is
      // trimmed/deduplicated of empty entries.
      await controller.setActiveSkills(<String>[' demo-skill ']);
      expect(c.read(chatControllerProvider).activeSkills, <String>[
        'demo-skill',
      ]);
      await controller.setActiveSkills(<String>['demo-skill', '']);
      expect(c.read(chatControllerProvider).activeSkills, <String>[
        'demo-skill',
      ]);
    });

    test('draft staging travels into the session created by the first '
        'message', () async {
      final ProviderContainer c = container();
      final ChatController controller = c.read(chatControllerProvider.notifier);
      await controller.setActiveSkills(<String>['demo-skill']);
      await controller.send('hello');
      final ChatState state = c.read(chatControllerProvider);
      expect(state.isRunning, isFalse);
      expect(state.sessionId, isNotNull);
      expect(state.activeSkills, <String>['demo-skill']);
      // And the session file persisted the selection.
      final SessionBundle? bundle = await c
          .read(chatStoreProvider)
          .loadBundle(state.sessionId!);
      expect(bundle, isNotNull);
      expect(bundle!.skills, <String>['demo-skill']);
    });

    test(
      'open session: apply persists into the CURRENT chat file only',
      () async {
        final ProviderContainer c = container();
        final ChatStore store = c.read(chatStoreProvider);
        // Two persisted chats, neither with skills.
        await store.save(
          id: 'chat-a',
          title: 'A',
          messages: <ChatMessage>[ChatMessage.user('a')],
        );
        await store.save(
          id: 'chat-b',
          title: 'B',
          messages: <ChatMessage>[ChatMessage.user('b')],
        );
        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.openChat(
          ChatSummary(id: 'chat-a', title: 'A', updatedAt: DateTime.now()),
        );
        await controller.setActiveSkills(<String>['demo-skill', 'other-skill']);
        expect(c.read(chatControllerProvider).activeSkills, <String>[
          'demo-skill',
          'other-skill',
        ]);
        // chat-a's stored file carries the selection…
        final Map<String, dynamic> rawA = const JsonDecoder().convert(
          File('${tempDir.path}/chats/chat-a.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(rawA['skills'], <String>['demo-skill', 'other-skill']);
        // …chat-b's file stays untouched (isolation).
        final Map<String, dynamic> rawB = const JsonDecoder().convert(
          File('${tempDir.path}/chats/chat-b.json').readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(rawB['skills'] ?? <String>[], <String>[]);
      },
    );

    test('selections are isolated per chat and restored on reopen', () async {
      final ProviderContainer c = container();
      final ChatStore store = c.read(chatStoreProvider);
      await store.save(
        id: 'chat-a',
        title: 'A',
        messages: <ChatMessage>[ChatMessage.user('a')],
        skills: <String>['demo-skill'],
      );
      await store.save(
        id: 'chat-b',
        title: 'B',
        messages: <ChatMessage>[ChatMessage.user('b')],
        skills: <String>['other-skill'],
      );
      final ChatController controller = c.read(chatControllerProvider.notifier);
      ChatSummary summary(String id, String title) =>
          ChatSummary(id: id, title: title, updatedAt: DateTime.now());

      await controller.openChat(summary('chat-a', 'A'));
      expect(c.read(chatControllerProvider).activeSkills, <String>[
        'demo-skill',
      ]);
      await controller.openChat(summary('chat-b', 'B'));
      expect(c.read(chatControllerProvider).activeSkills, <String>[
        'other-skill',
      ], reason: 'chat A selection must never leak into chat B');
      await controller.openChat(summary('chat-a', 'A'));
      expect(c.read(chatControllerProvider).activeSkills, <String>[
        'demo-skill',
      ], reason: 'returning to chat A restores its own selection');
    });

    test(
      'a new chat (draft) does not inherit the previous chat selection',
      () async {
        final ProviderContainer c = container();
        final ChatStore store = c.read(chatStoreProvider);
        await store.save(
          id: 'chat-a',
          title: 'A',
          messages: <ChatMessage>[ChatMessage.user('a')],
          skills: <String>['demo-skill'],
        );
        final ChatController controller = c.read(
          chatControllerProvider.notifier,
        );
        await controller.openChat(
          ChatSummary(id: 'chat-a', title: 'A', updatedAt: DateTime.now()),
        );
        expect(c.read(chatControllerProvider).activeSkills, <String>[
          'demo-skill',
        ]);
        await controller.newChat();
        expect(c.read(chatControllerProvider).activeSkills, isEmpty);
      },
    );
  });
}
