import 'dart:io';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args[0]
      : Platform.environment['LFM3_AUDIO_MODEL_PATH'] ??
            '/tmp/opencode/lfm3-audio/LFM3-Audio-2B-Q4_K_M.gguf';
  final projectorPath = args.length > 1
      ? args[1]
      : Platform.environment['LFM3_AUDIO_PROJECTOR_PATH'] ??
            '/tmp/opencode/lfm3-audio/mmproj-LFM3-Audio-2B-Q8_0.gguf';
  final text = args.length > 2
      ? args.sublist(2).join(' ')
      : 'Bonjour, ceci est un test de la synthèse vocale LFM3.';
  final outputWav = File('/tmp/opencode/lfm3-audio/tts.wav');

  final loadWatch = Stopwatch()..start();
  final engine = await LlamaEngine.load(
    LlamaModel(
      ModelSource.parse(modelPath),
      projector: ModelSource.parse(projectorPath),
    ),
    params: const LlamaCppModelParams(
      contextSize: 4096,
      gpuLayers: 0,
      numberOfThreads: 4,
    ),
  );
  loadWatch.stop();
  stdout.writeln('loaded in ${loadWatch.elapsed}');
  stdout.writeln('backend: ${await engine.getBackendName()}');
  stdout.writeln('supportsAudio: ${await engine.supportsAudio}');
  final ttsCaps = await engine.backendTextToSpeechCapabilities;
  stdout.writeln(
    'ttsCapabilities: supported=${ttsCaps.isSupported} '
    'model=${ttsCaps.model} reason=${ttsCaps.unsupportedReason}',
  );

  try {
    final ttsWatch = Stopwatch()..start();
    final tts = await engine.synthesizeTextToSpeechBackend(
      BackendTextToSpeechRequest(
        text: text,
        language: 'fr',
        maxFrames: 2048,
        temperature: 1.0,
        topK: 128,
        topP: 0.95,
      ),
      onProgress: (progress) {
        stdout.writeln(
          'tts ${progress.phase.name}: '
          '${progress.framesGenerated} frames',
        );
      },
    );
    ttsWatch.stop();

    final wav = TextToSpeechResult(
      samples: tts.samples,
      sampleRateHz: tts.sampleRateHz,
      channelCount: tts.channelCount,
      framesGenerated: tts.framesGenerated,
      truncated: tts.truncated,
    ).toWavBytes();
    await outputWav.writeAsBytes(wav);

    stdout.writeln(
      'tts: ${tts.framesGenerated} frames, '
      '${tts.sampleRateHz} Hz, ${tts.channelCount} ch, '
      '${tts.truncated ? 'truncated' : 'complete'} in ${ttsWatch.elapsed}',
    );
    stdout.writeln('tts wav: ${outputWav.path} (${wav.length} bytes)');

    final asrWatch = Stopwatch()..start();
    final asr = ChatSession(
      engine,
      maxContextTokens: 4096,
      systemPrompt: 'Perform ASR in French.',
    );
    final transcript = await asr
        .create(
          [
            const LlamaTextContent('<__media__>'),
            LlamaAudioContent(path: outputWav.path),
          ],
          enableThinking: false,
          params: const GenerationParams(
            maxTokens: 256,
            temp: 0,
            topK: 1,
            penalty: 1.0,
          ),
        )
        .text();
    asrWatch.stop();
    stdout.writeln('asr in ${asrWatch.elapsed}: ${transcript.trim()}');
  } finally {
    await engine.dispose();
  }
}
