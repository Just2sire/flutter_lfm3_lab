int _idCounter = 0;

String _newId() {
  _idCounter++;
  return '${DateTime.now().microsecondsSinceEpoch}-$_idCounter';
}

DateTime _parseDate(Object? value) {
  if (value is String) {
    return DateTime.tryParse(value) ?? DateTime.now();
  }
  return DateTime.now();
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.fromUser,
    required this.text,
    required this.createdAt,
    this.elapsedMs,
  });

  ChatMessage.user(String text)
    : this(id: _newId(), fromUser: true, text: text, createdAt: DateTime.now());

  ChatMessage.assistant(String text, {int? elapsedMs})
    : this(
        id: _newId(),
        fromUser: false,
        text: text,
        createdAt: DateTime.now(),
        elapsedMs: elapsedMs,
      );

  final String id;
  final bool fromUser;
  final String text;
  final DateTime createdAt;
  final int? elapsedMs;

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromUser': fromUser,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    if (elapsedMs != null) 'elapsedMs': elapsedMs,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? _newId(),
      fromUser: json['fromUser'] as bool? ?? false,
      text: json['text'] as String? ?? '',
      createdAt: _parseDate(json['createdAt']),
      elapsedMs: (json['elapsedMs'] as num?)?.toInt(),
    );
  }
}

class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
  });

  factory Conversation.empty() {
    final now = DateTime.now();
    return Conversation(
      id: _newId(),
      title: defaultTitle,
      createdAt: now,
      updatedAt: now,
      messages: [],
    );
  }

  static const defaultTitle = 'Nouvelle conversation';

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;

  String get preview {
    if (messages.isEmpty) return 'Aucun message';
    final text = messages.last.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return 'Message vide';
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messages': [for (final message in messages) message.toJson()],
  };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final messages = <ChatMessage>[];
    final rawMessages = json['messages'];
    if (rawMessages is List) {
      for (final raw in rawMessages) {
        if (raw is Map<String, dynamic>) {
          messages.add(ChatMessage.fromJson(raw));
        } else if (raw is Map) {
          messages.add(ChatMessage.fromJson(Map<String, dynamic>.from(raw)));
        }
      }
    }

    return Conversation(
      id: json['id'] as String? ?? _newId(),
      title: json['title'] as String? ?? defaultTitle,
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
      messages: messages,
    );
  }
}

class ConversationState {
  const ConversationState({
    required this.conversations,
    required this.activeId,
  });

  final List<Conversation> conversations;
  final String? activeId;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'activeId': activeId,
    'conversations': [
      for (final conversation in conversations) conversation.toJson(),
    ],
  };

  factory ConversationState.fromJson(Map<String, dynamic> json) {
    final conversations = <Conversation>[];
    final rawConversations = json['conversations'];
    if (rawConversations is List) {
      for (final raw in rawConversations) {
        if (raw is Map<String, dynamic>) {
          conversations.add(Conversation.fromJson(raw));
        } else if (raw is Map) {
          conversations.add(
            Conversation.fromJson(Map<String, dynamic>.from(raw)),
          );
        }
      }
    }

    final activeId = json['activeId'] as String?;
    return ConversationState(
      conversations: conversations,
      activeId: conversations.any((c) => c.id == activeId) ? activeId : null,
    );
  }
}
