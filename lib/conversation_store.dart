import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'conversation.dart';

class ConversationStore {
  ConversationStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<void> _queue = Future.value();

  Future<File> _file() async {
    final directory = await _directoryProvider();
    return File('${directory.path}/conversations.json');
  }

  Future<ConversationState> load() async {
    final file = await _file();
    if (!await file.exists()) {
      return const ConversationState(conversations: [], activeId: null);
    }

    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map<String, dynamic>) {
        return ConversationState.fromJson(raw);
      }
      if (raw is Map) {
        return ConversationState.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (error) {
      debugPrint('ConversationStore load failed: $error');
    }

    return const ConversationState(conversations: [], activeId: null);
  }

  Future<void> save(ConversationState state) {
    final data = jsonEncode(state.toJson());
    final result = _queue.then((_) => _write(data));
    _queue = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        debugPrint('ConversationStore save failed: $error');
      },
    );
    return result;
  }

  Future<void> _write(String data) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(data);

    try {
      await temp.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(data);
      if (await temp.exists()) await temp.delete();
    }
  }
}
