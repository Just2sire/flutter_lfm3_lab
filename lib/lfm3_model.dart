import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum Lfm3ModelKind { text, audio }

class Lfm3ModelFile {
  const Lfm3ModelFile({
    required this.fileName,
    required this.sizeBytes,
    required this.url,
    this.envOverride,
  });

  final String fileName;
  final int sizeBytes;
  final Uri url;
  final String? envOverride;
}

class Lfm3ModelSpec {
  const Lfm3ModelSpec({
    required this.kind,
    required this.label,
    required this.description,
    required this.model,
    this.projector,
  });

  final Lfm3ModelKind kind;
  final String label;
  final String description;
  final Lfm3ModelFile model;
  final Lfm3ModelFile? projector;

  bool get isAudio => projector != null;

  int get totalSizeBytes => model.sizeBytes + (projector?.sizeBytes ?? 0);

  List<Lfm3ModelFile> get files => [model, ?projector];
}

class Lfm3Model {
  static final text = Lfm3ModelSpec(
    kind: Lfm3ModelKind.text,
    label: 'LFM3-1.7B · texte',
    description: 'Chat texte rapide et léger.',
    model: Lfm3ModelFile(
      fileName: 'LFM3-1.7B-Q4_K_M.gguf',
      sizeBytes: 1099627808,
      url: Uri.parse(
        'https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/'
        'LFM3-1.7B-Q4_K_M.gguf',
      ),
      envOverride: 'LFM3_MODEL_PATH',
    ),
  );

  static final audio = Lfm3ModelSpec(
    kind: Lfm3ModelKind.audio,
    label: 'LFM3-Audio-2B · voix',
    description: 'Dictée, réponses texte et synthèse vocale.',
    model: Lfm3ModelFile(
      fileName: 'LFM3-Audio-2B-Q4_K_M.gguf',
      sizeBytes: 1099626016,
      url: Uri.parse(
        'https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/main/'
        'LFM3-Audio-2B-Q4_K_M.gguf',
      ),
      envOverride: 'LFM3_AUDIO_MODEL_PATH',
    ),
    projector: Lfm3ModelFile(
      fileName: 'mmproj-LFM3-Audio-2B-Q8_0.gguf',
      sizeBytes: 303811840,
      url: Uri.parse(
        'https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/main/'
        'mmproj-LFM3-Audio-2B-Q8_0.gguf',
      ),
      envOverride: 'LFM3_AUDIO_PROJECTOR_PATH',
    ),
  );

  static final all = [text, audio];

  static Lfm3ModelSpec byKind(Lfm3ModelKind kind) =>
      kind == Lfm3ModelKind.audio ? audio : text;

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

  static Future<File> file(Lfm3ModelSpec spec) => fileOf(spec.model);

  static Future<File?> projectorFile(Lfm3ModelSpec spec) async {
    final projector = spec.projector;
    return projector == null ? null : fileOf(projector);
  }

  static Future<bool> isReady(Lfm3ModelSpec spec) async {
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

  static Future<void> delete(Lfm3ModelSpec spec) async {
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
