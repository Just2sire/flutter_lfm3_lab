import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Lfm3Model {
  static const fileName = 'LFM3-1.7B-Q4_K_M.gguf';
  static const sizeBytes = 1099627808;

  static final Uri downloadUrl = Uri.parse(
    'https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/$fileName',
  );

  static Future<Directory> directory() async {
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/models');
  }

  static Future<File> file() async {
    final override = Platform.environment['LFM3_MODEL_PATH'];
    if (override != null && override.isNotEmpty) {
      return File(override);
    }
    final dir = await directory();
    return File('${dir.path}/$fileName');
  }

  static Future<bool> isReady() async {
    final model = await file();
    if (!await model.exists()) return false;
    if (await model.length() == sizeBytes) return true;
    await model.delete();
    return false;
  }

  static Future<void> delete() async {
    final model = await file();
    if (await model.exists()) await model.delete();
    final part = File('${model.path}.part');
    if (await part.exists()) await part.delete();
  }
}
