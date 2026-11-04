import 'dart:io';

import 'package:http/http.dart' as http;

import 'lfm3_model.dart';

class ModelDownloader {
  ModelDownloader({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<File> download({
    required void Function(int received, int? total) onProgress,
  }) async {
    final destination = await Lfm3Model.file();
    await destination.parent.create(recursive: true);
    final part = File('${destination.path}.part');
    if (await part.exists()) await part.delete();

    final response = await _client.send(
      http.Request('GET', Lfm3Model.downloadUrl),
    );
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw HttpException(
        'Téléchargement refusé (${response.statusCode})',
        uri: Lfm3Model.downloadUrl,
      );
    }

    final total = response.contentLength;
    final sink = part.openWrite();
    var received = 0;

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
    } finally {
      await sink.close();
    }

    if (total != null && received != total) {
      await part.delete();
      throw const HttpException('Téléchargement incomplet');
    }

    final length = await part.length();
    if (length != Lfm3Model.sizeBytes) {
      await part.delete();
      throw HttpException(
        'Taille inattendue : $length octets au lieu de ${Lfm3Model.sizeBytes}',
      );
    }

    await part.rename(destination.path);
    onProgress(length, length);
    return destination;
  }

  Future<void> delete() => Lfm3Model.delete();

  void close() => _client.close();
}
