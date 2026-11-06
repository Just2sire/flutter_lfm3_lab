import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_lfm3_lab/embedding_engine.dart';
import 'package:flutter_lfm3_lab/rag.dart';
import 'package:flutter_lfm3_lab/rag_service.dart';

void main() {
  final enabled = Platform.environment['RUN_RAG_REAL'] == '1';

  test(
    'real EmbeddingGemma-2 multimodal RAG probe',
    () async {
      final directory = await Directory.systemTemp.createTemp('lfm3_rag_probe');
      final textFile = File('${directory.path}/notes.txt');
      await textFile.writeAsString(
        'Le cercle rouge est dessiné sur un fond blanc. '
        'Un rectangle bleu vertical traverse le centre de l’image. '
        'Ce document parle aussi de photosynthèse et de jardinage.',
      );

      final embedding = EmbeddingEngine();
      final service = RagService(
        embedding: embedding,
        store: AttachmentStore(directoryProvider: () async => directory),
      );

      try {
        final watch = Stopwatch()..start();
        await embedding.load();
        watch.stop();
        stdout.writeln('loaded in ${watch.elapsed}');
        final caps = embedding.capabilities;
        stdout.writeln(
          'caps text=${caps?.text} image=${caps?.image} audio=${caps?.audio}',
        );

        final text = await service.addFile(
          conversationId: 'probe',
          sourcePath: textFile.path,
          name: 'notes.txt',
        );
        stdout.writeln('text chunks=${text.chunkCount}');

        final image = await service.addFile(
          conversationId: 'probe',
          sourcePath: '/tmp/opencode/embeddinggemma-2/test.png',
          name: 'test.png',
        );
        stdout.writeln('image chunks=${image.chunkCount}');

        final audio = await service.addFile(
          conversationId: 'probe',
          sourcePath: '/tmp/opencode/embeddinggemma-2/test.wav',
          name: 'test.wav',
        );
        stdout.writeln('audio chunks=${audio.chunkCount}');

        for (final query in [
          'Quelle forme rouge est sur l’image ?',
          'Que contient le document sur le jardinage ?',
          'Quel son entends-tu ?',
        ]) {
          final results = await service.search('probe', query);
          stdout.writeln('query: $query');
          for (final result in results) {
            stdout.writeln(
              '  ${result.score.toStringAsFixed(3)} '
              '${result.chunk.sourceName} (${result.chunk.kind.name})',
            );
          }
        }
      } finally {
        await embedding.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: !enabled,
  );
}
