import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args.first : 'models/LFM3-1.7B-Q4_K_M.gguf';

  final loadWatch = Stopwatch()..start();
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.parse(path)),
    params: const LlamaCppModelParams(
      contextSize: 4096,
      gpuLayers: 0,
      numberOfThreads: 4,
    ),
  );
  loadWatch.stop();
  stdout.writeln('loaded in ${loadWatch.elapsed}');
  stdout.writeln('backend: ${await engine.getBackendName()}');

  try {
    final generationWatch = Stopwatch()..start();
    final reply = await engine
        .create(
          const [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: 'Capitale du Togo ? Réponds en un mot.',
            ),
          ],
          enableThinking: false,
          params: const GenerationParams(
            maxTokens: 64,
            temp: 0.1,
            topK: 50,
            penalty: 1.1,
          ),
        )
        .text();
    generationWatch.stop();
    stdout.writeln('reply: $reply');
    stdout.writeln('generated in ${generationWatch.elapsed}');
  } finally {
    await engine.dispose();
  }
}
