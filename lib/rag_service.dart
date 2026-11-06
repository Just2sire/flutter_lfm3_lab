import 'dart:io';
import 'dart:math' as math;

import 'attachment_ingestor.dart';
import 'embedding_engine.dart';
import 'rag.dart';

class RagSearchResult {
  const RagSearchResult({required this.chunk, required this.score});

  final RagChunk chunk;
  final double score;
}

class RagService {
  RagService({
    required this.embedding,
    AttachmentStore? store,
    AttachmentIngestor? ingestor,
  }) : store = store ?? AttachmentStore(),
       ingestor = ingestor ?? AttachmentIngestor();

  final EmbeddingEngine embedding;
  final AttachmentStore store;
  final AttachmentIngestor ingestor;
  final Map<String, RagIndex> _indexes = {};

  Future<RagIndex> indexFor(String conversationId) async {
    final cached = _indexes[conversationId];
    if (cached != null) return cached;
    final index = await store.load(conversationId);
    _indexes[conversationId] = index;
    return index;
  }

  Future<RagAttachment> addFile({
    required String conversationId,
    required String sourcePath,
    required String name,
    void Function(String status)? onStatus,
  }) async {
    final kind = ragKindForFileName(name);
    if (kind == null) {
      throw FormatException(
        'Format non pris en charge pour « $name ». '
        'Formats acceptés : texte, image, WAV.',
      );
    }

    final storedPath = await store.importFile(
      conversationId: conversationId,
      sourcePath: sourcePath,
      name: name,
    );

    try {
      onStatus?.call('Extraction du contenu…');
      final chunks = await ingestor.ingest(file: File(storedPath), kind: kind);
      if (chunks.isEmpty) {
        throw const FormatException('Aucun contenu exploitable.');
      }

      onStatus?.call('Calcul des embeddings…');
      final vectors = await _embedChunks(kind, name, chunks);
      final index = await indexFor(conversationId);
      final attachmentId =
          '${DateTime.now().microsecondsSinceEpoch}-${index.attachments.length}';
      final attachment = RagAttachment(
        id: attachmentId,
        name: name,
        kind: kind,
        path: storedPath,
        sizeBytes: await File(storedPath).length(),
        chunkCount: chunks.length,
        createdAt: DateTime.now(),
      );

      final ragChunks = <RagChunk>[];
      for (var i = 0; i < chunks.length; i++) {
        final chunk = chunks[i];
        ragChunks.add(
          RagChunk(
            id: '$attachmentId-$i',
            attachmentId: attachmentId,
            sourceName: name,
            kind: kind,
            vector: vectors[i],
            text: chunk.text,
            path: chunk.path,
            startSample: chunk.startSample,
            endSample: chunk.endSample,
          ),
        );
      }

      index.attachments.add(attachment);
      index.chunks.addAll(ragChunks);
      await store.save(conversationId, index);
      return attachment;
    } catch (_) {
      try {
        await File(storedPath).delete();
      } catch (_) {
        // Ignore cleanup errors.
      }
      rethrow;
    }
  }

  Future<List<List<double>>> _embedChunks(
    RagAttachmentKind kind,
    String name,
    List<IngestedChunk> chunks,
  ) async {
    final vectors = List<List<double>?>.filled(chunks.length, null);
    final textDocuments = <EmbeddingTextDocument>[];
    final textIndexes = <int>[];

    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      if (chunk.text != null) {
        textDocuments.add(
          EmbeddingTextDocument(title: name, text: chunk.text!),
        );
        textIndexes.add(i);
      } else if (kind == RagAttachmentKind.image && chunk.path != null) {
        vectors[i] = await embedding.embedImage(chunk.path!);
      } else if (kind == RagAttachmentKind.audio && chunk.samples != null) {
        vectors[i] = await embedding.embedAudio(chunk.samples!);
      } else {
        throw const FormatException(
          'Contenu de pièce jointe non pris en charge.',
        );
      }
    }

    if (textDocuments.isNotEmpty) {
      final embedded = await embedding.embedDocuments(textDocuments);
      for (var i = 0; i < embedded.length; i++) {
        vectors[textIndexes[i]] = embedded[i];
      }
    }

    if (vectors.any((vector) => vector == null)) {
      throw StateError('Un extrait de la pièce jointe n’a pas pu être indexé.');
    }
    return [for (final vector in vectors) vector!];
  }

  Future<List<RagSearchResult>> search(
    String conversationId,
    String query, {
    int topK = 3,
    double minScore = 0.2,
  }) async {
    final index = await indexFor(conversationId);
    if (index.chunks.isEmpty || query.trim().isEmpty) return const [];

    final queryVector = await embedding.embedQuery(query);
    final results = <RagSearchResult>[];
    for (final chunk in index.chunks) {
      final score = _dot(queryVector, chunk.vector);
      if (score >= minScore) {
        results.add(RagSearchResult(chunk: chunk, score: score));
      }
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(topK).toList();
  }

  Future<void> removeAttachment(
    String conversationId,
    RagAttachment attachment,
  ) async {
    final index = await indexFor(conversationId);
    index.attachments.removeWhere((item) => item.id == attachment.id);
    index.chunks.removeWhere((chunk) => chunk.attachmentId == attachment.id);
    await store.save(conversationId, index);
    await store.deleteAttachment(attachment);
  }

  Future<void> deleteConversation(String conversationId) async {
    _indexes.remove(conversationId);
    await store.deleteConversation(conversationId);
  }

  void clearCache() => _indexes.clear();

  static double _dot(List<double> a, List<double> b) {
    final length = math.min(a.length, b.length);
    var sum = 0.0;
    for (var i = 0; i < length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }
}
