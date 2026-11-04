import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_lfm3_lab/conversation.dart';
import 'package:flutter_lfm3_lab/conversation_store.dart';

void main() {
  group('ChatMessage', () {
    test('round-trips through JSON', () {
      final message = ChatMessage.assistant('Bonjour', elapsedMs: 1234);
      final restored = ChatMessage.fromJson(message.toJson());

      expect(restored.id, message.id);
      expect(restored.fromUser, isFalse);
      expect(restored.text, 'Bonjour');
      expect(restored.elapsedMs, 1234);
      expect(restored.createdAt, message.createdAt);
    });

    test('falls back to defaults for missing fields', () {
      final restored = ChatMessage.fromJson(const {});

      expect(restored.fromUser, isFalse);
      expect(restored.text, isEmpty);
      expect(restored.elapsedMs, isNull);
    });
  });

  group('Conversation', () {
    test('preview uses the last message and truncates it', () {
      final conversation = Conversation.empty();
      conversation.messages.add(ChatMessage.user('Bonjour'));
      conversation.messages.add(
        ChatMessage.assistant(
          'Une réponse suffisamment longue pour être '
          'tronquée lors de l’affichage dans le tiroir des conversations.',
        ),
      );

      expect(conversation.preview, endsWith('…'));
      expect(conversation.preview.length, 81);
    });

    test('preview handles an empty conversation', () {
      expect(Conversation.empty().preview, 'Aucun message');
    });

    test('round-trips through JSON', () {
      final conversation = Conversation.empty();
      conversation.title = 'Test';
      conversation.messages.add(ChatMessage.user('Salut'));
      conversation.messages.add(ChatMessage.assistant('Coucou'));

      final restored = Conversation.fromJson(conversation.toJson());

      expect(restored.id, conversation.id);
      expect(restored.title, 'Test');
      expect(restored.messages.length, 2);
      expect(restored.messages.first.text, 'Salut');
      expect(restored.messages.last.text, 'Coucou');
    });
  });

  group('ConversationState', () {
    test('drops an unknown active id', () {
      final conversation = Conversation.empty();
      final state = ConversationState.fromJson({
        'activeId': 'unknown',
        'conversations': [conversation.toJson()],
      });

      expect(state.conversations.length, 1);
      expect(state.activeId, isNull);
    });

    test('keeps a known active id', () {
      final conversation = Conversation.empty();
      final state = ConversationState.fromJson({
        'activeId': conversation.id,
        'conversations': [conversation.toJson()],
      });

      expect(state.activeId, conversation.id);
    });
  });

  group('ConversationStore', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('lfm3_store_test');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    ConversationStore createStore() =>
        ConversationStore(directoryProvider: () async => directory);

    test('returns an empty state when no file exists', () async {
      final state = await createStore().load();

      expect(state.conversations, isEmpty);
      expect(state.activeId, isNull);
    });

    test('saves and reloads conversations', () async {
      final conversation = Conversation.empty();
      conversation.title = 'Persistée';
      conversation.messages.add(ChatMessage.user('Question'));
      conversation.messages.add(ChatMessage.assistant('Réponse'));

      final store = createStore();
      await store.save(
        ConversationState(
          conversations: [conversation],
          activeId: conversation.id,
        ),
      );

      final restored = await createStore().load();

      expect(restored.activeId, conversation.id);
      expect(restored.conversations.single.title, 'Persistée');
      expect(restored.conversations.single.messages.length, 2);
      expect(File('${directory.path}/conversations.json').existsSync(), isTrue);
    });

    test('ignores a corrupt file', () async {
      await File('${directory.path}/conversations.json')
          .writeAsString('not json');

      final state = await createStore().load();

      expect(state.conversations, isEmpty);
    });
  });
}
