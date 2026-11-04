import 'package:llamadart/llamadart.dart';

import 'lfm3_model.dart';

class ChatTurn {
  const ChatTurn({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;
}

class Lfm3Engine {
  static const contextSize = 4096;

  static const systemPrompt =
      'Tu es un assistant concis et utile. Réponds en français.';

  static const generationParams = GenerationParams(
    maxTokens: 512,
    temp: 0.1,
    topK: 50,
    penalty: 1.1,
  );

  LlamaEngine? _engine;
  ChatSession? _session;

  bool get isLoaded => _engine != null;

  Future<void> load({List<ChatTurn> history = const []}) async {
    if (_engine != null) return;

    final model = await Lfm3Model.file();
    if (!await model.exists()) {
      throw StateError('Modèle introuvable : ${model.path}');
    }

    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.parse(model.path)),
      params: const LlamaCppModelParams(
        contextSize: contextSize,
        gpuLayers: 0,
        numberOfThreads: 4,
      ),
    );

    final session = ChatSession(
      engine,
      maxContextTokens: contextSize,
      systemPrompt: systemPrompt,
    );

    for (final turn in history) {
      session.addMessage(
        LlamaChatMessage.fromText(
          role: turn.fromUser ? LlamaChatRole.user : LlamaChatRole.assistant,
          text: turn.text,
        ),
      );
    }

    _engine = engine;
    _session = session;
  }

  Stream<String> chat(
    String userMessage, {
    bool enableThinking = false,
  }) async* {
    final session = _session;
    if (session == null) {
      throw StateError('Le modèle n’est pas chargé.');
    }

    await for (final chunk in session.create(
      [LlamaTextContent(userMessage)],
      enableThinking: enableThinking,
      params: generationParams,
    )) {
      if (chunk.text.isNotEmpty) yield chunk.text;
    }
  }

  void stop() => _engine?.cancelGeneration();

  void reset() => _session?.reset();

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    _session = null;
  }
}
