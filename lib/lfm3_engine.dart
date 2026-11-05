import 'dart:typed_data';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';

import 'lfm3_model.dart';

class ChatTurn {
  const ChatTurn({required this.fromUser, required this.text});

  final bool fromUser;
  final String text;
}

class Lfm3Engine {
  Lfm3Engine({required this.spec});

  static const contextSize = 4096;

  static const systemPrompt =
      'Tu es un assistant concis et utile. Réponds en français.';

  static const generationParams = GenerationParams(
    maxTokens: 512,
    temp: 0.1,
    topK: 50,
    penalty: 1.1,
  );

  final Lfm3ModelSpec spec;

  LlamaEngine? _engine;
  ChatSession? _session;

  bool get isLoaded => _engine != null;

  bool get isAudioCapable => spec.isAudio;

  Future<void> load({List<ChatTurn> history = const []}) async {
    if (_engine != null) return;

    final model = await Lfm3Model.file(spec);
    if (!await model.exists()) {
      throw StateError('Modèle introuvable : ${model.path}');
    }

    final projector = await Lfm3Model.projectorFile(spec);
    if (projector != null && !await projector.exists()) {
      throw StateError('Projecteur audio introuvable : ${projector.path}');
    }

    final engine = await LlamaEngine.load(
      LlamaModel(
        ModelSource.parse(model.path),
        projector: projector == null ? null : ModelSource.parse(projector.path),
      ),
      params: const LlamaCppModelParams(
        contextSize: contextSize,
        gpuLayers: 0,
        numberOfThreads: 4,
      ),
    );

    try {
      _session = _createSession(engine, history);
      _engine = engine;
    } catch (_) {
      await engine.dispose();
      rethrow;
    }
  }

  ChatSession _createSession(LlamaEngine engine, List<ChatTurn> history) {
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

    return session;
  }

  void setHistory(List<ChatTurn> history) {
    final engine = _engine;
    if (engine == null) return;
    _session = _createSession(engine, history);
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

  Future<String> transcribe(
    String wavPath, {
    String language = 'French',
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw StateError('Le modèle n’est pas chargé.');
    }

    final session = ChatSession(
      engine,
      maxContextTokens: contextSize,
      systemPrompt: 'Perform ASR in $language.',
    );

    final buffer = StringBuffer();
    await for (final chunk in session.create(
      [const LlamaTextContent('<__media__>'), LlamaAudioContent(path: wavPath)],
      enableThinking: false,
      params: const GenerationParams(
        maxTokens: 512,
        temp: 0,
        topK: 1,
        penalty: 1.0,
      ),
    )) {
      buffer.write(chunk.text);
    }

    return buffer.toString().trim();
  }

  Future<Uint8List> synthesize(
    String text, {
    String language = 'fr',
    int maxFrames = 2048,
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw StateError('Le modèle n’est pas chargé.');
    }
    if (!spec.isAudio) {
      throw StateError('Le modèle audio n’est pas chargé.');
    }

    final result = await engine.synthesizeTextToSpeechBackend(
      BackendTextToSpeechRequest(
        text: text,
        language: language,
        maxFrames: maxFrames,
        temperature: 1.0,
        topK: 128,
        topP: 0.95,
      ),
    );

    return TextToSpeechResult(
      samples: result.samples,
      sampleRateHz: result.sampleRateHz,
      channelCount: result.channelCount,
      framesGenerated: result.framesGenerated,
      truncated: result.truncated,
    ).toWavBytes();
  }

  void stop() => _engine?.cancelGeneration();

  void stopSpeech() => _engine?.cancelTextToSpeechBackend();

  void reset() => _session?.reset();

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
    _session = null;
  }
}
