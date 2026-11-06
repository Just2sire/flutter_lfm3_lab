import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_lfm3_lab/attachment_ingestor.dart';
import 'package:flutter_lfm3_lab/embedding_engine.dart';
import 'package:flutter_lfm3_lab/rag.dart';
import 'package:flutter_lfm3_lab/rag_service.dart';

class _FakeEmbedding extends EmbeddingEngine {
  @override
  Future<List<double>> embedQuery(String text) async {
    return text.toLowerCase().contains('alpha') ? [1.0, 0.0] : [0.0, 1.0];
  }

  @override
  Future<List<List<double>>> embedDocuments(
    List<EmbeddingTextDocument> documents,
  ) async {
    return [
      for (final document in documents)
        document.text.toLowerCase().contains('alpha') ? [1.0, 0.0] : [0.0, 1.0],
    ];
  }
}

void main() {
  group('chunkText', () {
    test('returns one chunk for short text', () {
      expect(AttachmentIngestor.chunkText('Bonjour'), ['Bonjour']);
    });

    test('splits long text into bounded chunks', () {
      final text = List.generate(
        80,
        (index) => 'Phrase numéro $index. ',
      ).join();
      final chunks = AttachmentIngestor.chunkText(text, chunkSize: 200);

      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.length <= 200), isTrue);
      expect(chunks.every((chunk) => chunk.isNotEmpty), isTrue);
    });

    test('ignores empty text', () {
      expect(AttachmentIngestor.chunkText('   \n  '), isEmpty);
    });
  });

  group('WavAudio', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('lfm3_wav_test');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('decodes and resamples a stereo 8 kHz WAV to mono 16 kHz', () async {
      final file = File('${directory.path}/test.wav');
      await file.writeAsBytes(_wavBytes(sampleRate: 8000, channels: 2));

      final audio = await WavAudio.read(file);

      expect(audio.sourceSampleRate, 8000);
      expect(audio.sourceChannels, 2);
      expect(audio.samples.length, closeTo(16000, 2));
      expect(audio.samples.every((value) => value.isFinite), isTrue);
    });

    test('keeps 16 kHz mono audio unchanged', () async {
      final file = File('${directory.path}/test16.wav');
      await file.writeAsBytes(_wavBytes(sampleRate: 16000, channels: 1));

      final audio = await WavAudio.read(file);

      expect(audio.sourceSampleRate, 16000);
      expect(audio.sourceChannels, 1);
      expect(audio.samples.length, 16000);
    });
  });

  group('RagIndex', () {
    test('round-trips vectors and metadata through JSON', () {
      final attachment = RagAttachment(
        id: 'a1',
        name: 'notes.txt',
        kind: RagAttachmentKind.text,
        path: '/tmp/notes.txt',
        sizeBytes: 42,
        chunkCount: 1,
        createdAt: DateTime(2026, 1, 2, 3, 4, 5),
      );
      final index = RagIndex(
        attachments: [attachment],
        chunks: [
          RagChunk(
            id: 'c1',
            attachmentId: 'a1',
            sourceName: 'notes.txt',
            kind: RagAttachmentKind.text,
            vector: const [0.1, 0.2, 0.3],
            text: 'Bonjour',
          ),
        ],
      );

      final restored = RagIndex.fromJson(index.toJson());

      expect(restored.attachments.single.name, 'notes.txt');
      expect(restored.chunks.single.text, 'Bonjour');
      expect(restored.chunks.single.vector, hasLength(3));
      expect(restored.chunks.single.vector[0], closeTo(0.1, 1e-6));
    });
  });

  group('RagService', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('lfm3_rag_test');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('indexes, searches and removes a text attachment', () async {
      final source = File('${directory.path}/source.txt');
      await source.writeAsString('Le document alpha contient la réponse.');
      final store = AttachmentStore(directoryProvider: () async => directory);
      final service = RagService(embedding: _FakeEmbedding(), store: store);

      final attachment = await service.addFile(
        conversationId: 'conv-1',
        sourcePath: source.path,
        name: 'source.txt',
      );

      expect(attachment.chunkCount, 1);
      expect(File(attachment.path).existsSync(), isTrue);

      final results = await service.search('conv-1', 'alpha');
      expect(results, hasLength(1));
      expect(results.single.chunk.sourceName, 'source.txt');
      expect(results.single.score, closeTo(1.0, 1e-6));

      await service.removeAttachment('conv-1', attachment);
      expect(File(attachment.path).existsSync(), isFalse);
      expect(await service.search('conv-1', 'alpha'), isEmpty);
    });

    test('deletes a conversation index and attachments', () async {
      final source = File('${directory.path}/source.txt');
      await source.writeAsString('Contenu alpha.');
      final store = AttachmentStore(directoryProvider: () async => directory);
      final service = RagService(embedding: _FakeEmbedding(), store: store);

      final attachment = await service.addFile(
        conversationId: 'conv-2',
        sourcePath: source.path,
        name: 'source.txt',
      );
      await service.deleteConversation('conv-2');

      expect(File(attachment.path).existsSync(), isFalse);
      expect(await service.indexFor('conv-2'), isEmpty);
    });
  });
}

Uint8List _wavBytes({required int sampleRate, required int channels}) {
  const seconds = 1;
  final frames = sampleRate * seconds;
  final dataSize = frames * channels * 2;
  final bytes = Uint8List(44 + dataSize);
  final data = ByteData.sublistView(bytes);

  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, dataSize, Endian.little);

  for (var i = 0; i < frames; i++) {
    final value = (i % 100) * 100;
    for (var channel = 0; channel < channels; channel++) {
      final offset = 44 + (i * channels + channel) * 2;
      data.setInt16(offset, value, Endian.little);
    }
  }
  return bytes;
}
