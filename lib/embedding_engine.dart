import 'dart:math' as math;
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

import 'embedding_model.dart';

class EmbeddingTextDocument {
  const EmbeddingTextDocument({required this.title, required this.text});

  final String title;
  final String text;
}

class EmbeddingEngine {
  static const outputDimensions = 256;
  static const _contextSize = 8192;
  static const _batchSize = 16;

  LlamaEngine? _engine;
  LlamaEmbeddingCapabilities? _capabilities;
  Future<void>? _loading;

  bool get isLoaded => _engine != null;

  LlamaEmbeddingCapabilities? get capabilities => _capabilities;

  Future<void> load() {
    if (_engine != null) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      if (!await EmbeddingModel.isReady()) {
        throw StateError('Le modèle d’embeddings est absent.');
      }
      final model = await EmbeddingModel.modelFile();
      final projector = await EmbeddingModel.projectorFile();

      final engine = await LlamaEngine.load(
        LlamaModel(
          ModelSource.parse(model.path),
          projector: ModelSource.parse(projector.path),
        ),
        params: const LlamaCppModelParams(
          contextSize: _contextSize,
          batchSize: 2048,
          microBatchSize: 2048,
          gpuLayers: 0,
          numberOfThreads: 4,
        ),
      );

      try {
        final capabilities = await engine.embeddingCapabilities;
        if (!capabilities.text) {
          throw StateError(
            'Le modèle d’embeddings ne prend pas en charge le texte.',
          );
        }
        _engine = engine;
        _capabilities = capabilities;
      } catch (_) {
        await engine.dispose();
        rethrow;
      }
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Future<List<double>> embedQuery(String text) async {
    final vectors = await _embedInputs([
      LlamaEmbeddingInput([
        LlamaTextContent('task: question answering | query: ${text.trim()}'),
      ]),
    ]);
    return vectors.single;
  }

  Future<List<List<double>>> embedDocuments(
    List<EmbeddingTextDocument> documents,
  ) async {
    if (documents.isEmpty) return const [];
    final vectors = <List<double>>[];
    for (var start = 0; start < documents.length; start += _batchSize) {
      final end = math.min(start + _batchSize, documents.length);
      final batch = documents
          .sublist(start, end)
          .map(
            (document) => LlamaEmbeddingInput([
              LlamaTextContent(
                'title: ${document.title} | text: ${document.text}',
              ),
            ]),
          )
          .toList();
      vectors.addAll(await _embedInputs(batch));
    }
    return vectors;
  }

  Future<List<double>> embedImage(String path) async {
    final capabilities = _requireCapabilities();
    if (!capabilities.image) {
      throw StateError(
        capabilities.mediaUnsupportedReason ??
            'Les embeddings d’image ne sont pas disponibles.',
      );
    }
    final vectors = await _embedInputs([
      LlamaEmbeddingInput([LlamaImageContent(path: path)]),
    ]);
    return vectors.single;
  }

  Future<List<double>> embedAudio(Float32List samples) async {
    final capabilities = _requireCapabilities();
    if (!capabilities.audio) {
      throw StateError(
        capabilities.mediaUnsupportedReason ??
            'Les embeddings audio ne sont pas disponibles.',
      );
    }
    final vectors = await _embedInputs([
      LlamaEmbeddingInput([LlamaAudioContent(samples: samples)]),
    ]);
    return vectors.single;
  }

  LlamaEmbeddingCapabilities _requireCapabilities() {
    final capabilities = _capabilities;
    if (capabilities == null) {
      throw StateError('Le modèle d’embeddings n’est pas chargé.');
    }
    return capabilities;
  }

  Future<List<List<double>>> _embedInputs(
    List<LlamaEmbeddingInput> inputs,
  ) async {
    final engine = _engine;
    if (engine == null) {
      throw StateError('Le modèle d’embeddings n’est pas chargé.');
    }
    final vectors = await engine.embedContentBatch(inputs);
    return [for (final vector in vectors) _reduce(vector)];
  }

  List<double> _reduce(List<double> vector) {
    final length = math.min(outputDimensions, vector.length);
    final reduced = Float32List(length);
    var sum = 0.0;
    for (var i = 0; i < length; i++) {
      final value = vector[i];
      if (!value.isFinite) {
        throw StateError(
          'Le modèle d’embeddings a produit une valeur invalide.',
        );
      }
      reduced[i] = value;
      sum += value * value;
    }
    final norm = math.sqrt(sum);
    if (norm == 0) {
      throw StateError('Le modèle d’embeddings a produit un vecteur vide.');
    }
    return [for (final value in reduced) value / norm];
  }

  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    _capabilities = null;
    _loading = null;
    await engine?.dispose();
  }
}
