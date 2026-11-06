import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'lfm3_model.dart';

class EmbeddingModelSpec {
  const EmbeddingModelSpec({
    required this.label,
    required this.description,
    required this.model,
    required this.projector,
  });

  final String label;
  final String description;
  final Lfm3ModelFile model;
  final Lfm3ModelFile projector;

  List<Lfm3ModelFile> get files => [model, projector];

  int get totalSizeBytes => model.sizeBytes + projector.sizeBytes;
}

class EmbeddingModel {
  static final spec = EmbeddingModelSpec(
    label: 'EmbeddingGemma-2 · recherche',
    description:
        'Indexe les pièces jointes texte, image et audio pour retrouver '
        'les passages pertinents.',
    model: Lfm3ModelFile(
      fileName: 'embeddinggemma-2-Q8_0.gguf',
      sizeBytes: 309855456,
      url: Uri.parse(
        'https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main/'
        'embeddinggemma-2-Q8_0.gguf',
      ),
      envOverride: 'EMBEDDINGGEMMA_MODEL_PATH',
    ),
    projector: Lfm3ModelFile(
      fileName: 'mmproj-embeddinggemma-2-Q8_0.gguf',
      sizeBytes: 554821056,
      url: Uri.parse(
        'https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main/'
        'mmproj-embeddinggemma-2-Q8_0.gguf',
      ),
      envOverride: 'EMBEDDINGGEMMA_PROJECTOR_PATH',
    ),
  );

  static Future<Directory> directory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/models');
  }

  static String? _overrideFor(Lfm3ModelFile file) {
    final name = file.envOverride;
    if (name == null) return null;
    final value = Platform.environment[name];
    return value == null || value.isEmpty ? null : value;
  }

  static bool isOverridden(Lfm3ModelFile file) => _overrideFor(file) != null;

  static Future<File> fileOf(Lfm3ModelFile file) async {
    final override = _overrideFor(file);
    if (override != null) return File(override);
    final dir = await directory();
    return File('${dir.path}/${file.fileName}');
  }

  static Future<File> modelFile() => fileOf(spec.model);

  static Future<File> projectorFile() => fileOf(spec.projector);

  static Future<bool> isReady() async {
    for (final file in spec.files) {
      final resolved = await fileOf(file);
      if (!await resolved.exists()) return false;
      if (isOverridden(file)) continue;
      if (await resolved.length() == file.sizeBytes) continue;
      await resolved.delete();
      return false;
    }
    return true;
  }

  static Future<void> delete() async {
    for (final file in spec.files) {
      final resolved = await fileOf(file);
      if (!isOverridden(file)) {
        if (await resolved.exists()) await resolved.delete();
        final part = File('${resolved.path}.part');
        if (await part.exists()) await part.delete();
      }
    }
  }
}
