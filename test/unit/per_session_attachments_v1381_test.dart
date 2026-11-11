import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noah/di.dart';
import 'package:noah/models/models.dart';
import 'package:noah/services/agent_controller.dart';
import 'package:noah/services/llm_client.dart';

import '../support/test_doubles.dart';

/// v1.38.1 — staged attachments and composer draft text are PER CHAT:
/// switching chats swaps in the displayed chat's own list (preserve, not
/// clear) and no chat ever sees another's staged files or draft text.
Future<ProviderContainer> _container(Directory dir) async {
  final ProviderContainer container = ProviderContainer(
    overrides: testOverrides(
      llm: ScriptedLlmClient(<AssistantTurn>[AssistantTurn(content: 'ok')]),
      dir: dir,
      settings: AppSettings(apiKey: 'test-key', autoTitle: false),
    ),
  );
  addTearDown(container.dispose);
  return container;
}

ChatAttachment _attachment(String name) => ChatAttachment(
  name: name,
  path: '${Directory.systemTemp.path}/zagents_v1381_$name',
  sizeBytes: 3,
  kind: AttachmentKind.text,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zagents_v1381_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('per-chat staged attachments (preserved, isolated)', () {
    test('each chat keeps its own staged files across switches', () async {
      final ProviderContainer container = await _container(tempDir);
      final ChatController controller = container.read(
        chatControllerProvider.notifier,
      );

      // Session A.
      await controller.send('chat satu');
      final String? idA = container.read(chatControllerProvider).sessionId;

      // Stage a file on A (the composer writes into the provider view).
      final ChatAttachment attA = _attachment('a.txt');
      container.read(pendingAttachmentsProvider.notifier).state =
          <ChatAttachment>[attA];

      // New chat: the draft slot starts with ITS OWN (empty) list.
      await controller.newChat();
      expect(container.read(pendingAttachmentsProvider), isEmpty);

      // Draft stage + session B.
      final ChatAttachment attDraft = _attachment('draft.txt');
      container.read(pendingAttachmentsProvider.notifier).state =
          <ChatAttachment>[attDraft];
      await controller.send('chat dua');
      final String? idB = container.read(chatControllerProvider).sessionId;
      expect(idB, isNot(idA));

      // Stage B's own file, then switch back to A.
      final ChatAttachment attB = _attachment('b.txt');
      container.read(pendingAttachmentsProvider.notifier).state =
          <ChatAttachment>[attB];
      await controller.openChat(
        ChatSummary(id: idA!, title: 'A', updatedAt: DateTime.now()),
      );
      final List<String> namesA = container
          .read(pendingAttachmentsProvider)
          .map((ChatAttachment a) => a.name)
          .toList();
      expect(namesA, contains('a.txt'));
      expect(namesA, isNot(contains('b.txt')));
      expect(namesA, isNot(contains('draft.txt')));

      // Back to B: only B's list.
      await controller.openChat(
        ChatSummary(id: idB!, title: 'B', updatedAt: DateTime.now()),
      );
      expect(
        container
            .read(pendingAttachmentsProvider)
            .map((ChatAttachment a) => a.name),
        contains('b.txt'),
      );

      // A send consumes the staged list of the SENDING chat only (the
      // composer clears the view, send drops the store entry).
      final List<ChatAttachment> staged = container.read(
        pendingAttachmentsProvider,
      );
      container.read(pendingAttachmentsProvider.notifier).state =
          const <ChatAttachment>[];
      await container
          .read(chatControllerProvider.notifier)
          .send('pakai b', attachments: staged);
      expect(container.read(pendingAttachmentsProvider), isEmpty);
      // The store entry is gone too: switching away and back stays empty.
      await controller.openChat(
        ChatSummary(id: idA, title: 'A', updatedAt: DateTime.now()),
      );
      await controller.openChat(
        ChatSummary(id: idB, title: 'B', updatedAt: DateTime.now()),
      );
      expect(container.read(pendingAttachmentsProvider), isEmpty);
    });

    test('deleting a chat removes its staged list', () async {
      final ProviderContainer container = await _container(tempDir);
      final ChatController controller = container.read(
        chatControllerProvider.notifier,
      );
      await controller.send('chat sementara');
      final String? id = container.read(chatControllerProvider).sessionId;
      container.read(pendingAttachmentsProvider.notifier).state =
          <ChatAttachment>[_attachment('x.txt')];
      await controller.newChat();
      await controller.deleteChat(id!);
      await controller.openChat(
        ChatSummary(id: id, title: 'gone', updatedAt: DateTime.now()),
      );
      expect(container.read(pendingAttachmentsProvider), isEmpty);
    });
  });

  group('per-chat composer draft text', () {
    test('draft text travels with its own chat', () async {
      final ProviderContainer container = await _container(tempDir);
      final ChatController controller = container.read(
        chatControllerProvider.notifier,
      );

      controller.setDraftText(null, 'teks draft');
      expect(controller.draftTextFor(null), 'teks draft');

      await controller.send('mulai chat A');
      final String? idA = container.read(chatControllerProvider).sessionId;
      controller.setDraftText(idA, 'teks chat A');

      // Other chats never see A's draft; the draft slot keeps its own.
      expect(controller.draftTextFor('other-session'), isEmpty);
      expect(controller.draftTextFor(null), 'teks draft');
      expect(controller.draftTextFor(idA), 'teks chat A');

      // Deleting a chat drops its draft text.
      await controller.newChat();
      await controller.deleteChat(idA!);
      expect(controller.draftTextFor(idA), isEmpty);
    });
  });
}
