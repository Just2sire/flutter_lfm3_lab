import 'dart:io';

import 'package:http/http.dart' as http;

import 'lfm3_model.dart';

class ModelDownloader {
  ModelDownloader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<void> download(
    Lfm3ModelSpec spec, {
    required void Function(int received, int? total) onProgress,
  }) async {
    final total = spec.totalSizeBytes;
    var offset = 0;

    for (final file in spec.files) {
      final destination = await Lfm3Model.fileOf(file);
      if (await _isComplete(destination, file.sizeBytes)) {
        offset += file.sizeBytes;
        onProgress(offset, total);
        continue;
      }

      await _downloadFile(
        file,
        destination,
        offset: offset,
        total: total,
        onProgress: onProgress,
      );
      offset += file.sizeBytes;
    }

    onProgress(total, total);
  }

  Future<bool> _isComplete(File file, int expectedSize) async {
    if (!await file.exists()) return false;
    if (await file.length() == expectedSize) return true;
    await file.delete();
    return false;
  }

  Future<void> _downloadFile(
    Lfm3ModelFile file,
    File destination, {
    required int offset,
    required int total,
    required void Function(int received, int? total) onProgress,
  }) async {
    await destination.parent.create(recursive: true);
    final part = File('${destination.path}.part');

    var start = await part.exists() ? await part.length() : 0;
    if (start > file.sizeBytes) {
      await part.delete();
      start = 0;
    }

    if (start == file.sizeBytes) {
      await part.rename(destination.path);
      onProgress(offset + file.sizeBytes, total);
      return;
    }

    final request = http.Request('GET', file.url);
    if (start > 0) request.headers['Range'] = 'bytes=$start-';

    final response = await _client.send(request);
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.stream.drain<void>();
      throw HttpException(
        'Téléchargement refusé (${response.statusCode})',
        uri: file.url,
      );
    }

    final append = start > 0 && response.statusCode == 206;
    if (!append) start = 0;

    final sink = part.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );
    var received = start;

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(offset + received, total);
      }
    } finally {
      await sink.close();
    }

    if (received != file.sizeBytes) {
      await part.delete();
      throw HttpException(
        'Taille inattendue : $received octets au lieu de '
        '${file.sizeBytes} pour ${file.fileName}',
        uri: file.url,
      );
    }

    await part.rename(destination.path);
  }

  Future<void> delete(Lfm3ModelSpec spec) => Lfm3Model.delete(spec);

  void close() => _client.close();
}
