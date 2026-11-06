import 'dart:io';
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final modelPath =
      args.isNotEmpty
          ? args[0]
          : Platform.environment['EMBEDDINGGEMMA_MODEL_PATH'] ??
                '/tmp/opencode/embeddinggemma-2/embeddinggemma-2-Q8_0.gguf';
  final projectorPath =
      args.length > 1
          ? args[1]
          : Platform.environment['EMBEDDINGGEMMA_PROJECTOR_PATH'] ??
                '/tmp/opencode/embeddinggemma-2/mmproj-embeddinggemma-2-Q8_0.gguf';
  final imagePath =
      args.length > 2
          ? args[2]
          : '/tmp/opencode/embeddinggemma-2/test.png';
  final audioPath =
      args.length > 3
          ? args[3]
          : '/tmp/opencode/embeddinggemma-2/test.wav';

  final loadWatch = Stopwatch()..start();
  final engine = await LlamaEngine.load(
    LlamaModel(
      ModelSource.parse(modelPath),
      projector: ModelSource.parse(projectorPath),
    ),
    params: const LlamaCppModelParams(
      contextSize: 8192,
      batchSize: 2048,
      microBatchSize: 2048,
      gpuLayers: 0,
      numberOfThreads: 4,
    ),
  );
  loadWatch.stop();
  stdout.writeln('loaded in ${loadWatch.elapsed}');
  stdout.writeln('backend: ${await engine.getBackendName()}');
  stdout.writeln('supportsEmbeddings: ${engine.supportsEmbeddings}');
  stdout.writeln('supportsAudio: ${await engine.supportsAudio}');
  stdout.writeln('supportsVision: ${await engine.supportsVision}');

  try {
    final caps = await engine.embeddingCapabilities;
    stdout.writeln(
      'capabilities: text=${caps.text} image=${caps.image} audio=${caps.audio} '
      'reason=${caps.mediaUnsupportedReason}',
    );

    final query = await engine.embedContent(
      LlamaEmbeddingInput(const [
        LlamaTextContent(
          'task: question answering | query: What is in the test image?',
        ),
      ]),
    );
    stdout.writeln('query vector: ${query.length} dims, norm=${_norm(query)}');

    final document = await engine.embedContent(
      LlamaEmbeddingInput(const [
        LlamaTextContent(
          'title: test | text: The test image contains a red circle and a '
          'blue vertical rectangle.',
        ),
      ]),
    );
    stdout.writeln(
      'text document: ${document.length} dims, '
      'cos(query,doc)=${_cosine(query, document)}',
    );

    if (caps.image) {
      final image = await engine.embedContent(
        LlamaEmbeddingInput([LlamaImageContent(path: imagePath)]),
      );
      stdout.writeln(
        'image: ${image.length} dims, cos(query,image)=${_cosine(query, image)}',
      );
    }

    if (caps.audio) {
      final audio = await engine.embedContent(
        LlamaEmbeddingInput([LlamaAudioContent(path: audioPath)]),
      );
      stdout.writeln(
        'audio: ${audio.length} dims, cos(query,audio)=${_cosine(query, audio)}',
      );
    }
  } finally {
    await engine.dispose();
  }
}

double _norm(List<double> v) =>
    math.sqrt(v.fold<double>(0, (sum, x) => sum + x * x));

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot / (_norm(a) * _norm(b));
}
