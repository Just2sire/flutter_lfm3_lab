import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'rag.dart';

class IngestedChunk {
  const IngestedChunk({
    this.text,
    this.path,
    this.samples,
    this.startSample,
    this.endSample,
  });

  final String? text;
  final String? path;
  final Float32List? samples;
  final int? startSample;
  final int? endSample;
}

class AttachmentIngestor {
  static const maxTextBytes = 4 * 1024 * 1024;
  static const maxAudioSeconds = 300;
  static const audioSegmentSeconds = 60;
  static const audioSampleRate = 16000;

  Future<List<IngestedChunk>> ingest({
    required File file,
    required RagAttachmentKind kind,
  }) async {
    switch (kind) {
      case RagAttachmentKind.text:
        return _ingestText(file);
      case RagAttachmentKind.image:
        return [IngestedChunk(path: file.path)];
      case RagAttachmentKind.audio:
        return _ingestAudio(file);
    }
  }

  Future<List<IngestedChunk>> _ingestText(File file) async {
    if (await file.length() > maxTextBytes) {
      throw const FormatException('Document trop volumineux (maximum 4 Mo).');
    }
    final text = await file.readAsString();
    return [for (final chunk in chunkText(text)) IngestedChunk(text: chunk)];
  }

  Future<List<IngestedChunk>> _ingestAudio(File file) async {
    final audio = await WavAudio.read(file);
    final duration = audio.samples.length / audioSampleRate;
    if (duration > maxAudioSeconds) {
      throw const FormatException('Audio trop long (maximum 5 minutes).');
    }
    if (audio.samples.isEmpty) {
      throw const FormatException('Audio vide.');
    }

    final segmentLength = audioSegmentSeconds * audioSampleRate;
    final chunks = <IngestedChunk>[];
    for (var start = 0; start < audio.samples.length; start += segmentLength) {
      final end = math.min(start + segmentLength, audio.samples.length);
      chunks.add(
        IngestedChunk(
          path: file.path,
          samples: Float32List.fromList(audio.samples.sublist(start, end)),
          startSample: start,
          endSample: end,
        ),
      );
    }
    return chunks;
  }

  static List<String> chunkText(
    String text, {
    int chunkSize = 900,
    int overlap = 150,
  }) {
    final normalized = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'\u0000'), '')
        .trim();
    if (normalized.isEmpty) return const [];
    if (normalized.length <= chunkSize) return [normalized];

    final chunks = <String>[];
    var start = 0;
    while (start < normalized.length) {
      var end = math.min(start + chunkSize, normalized.length);
      if (end < normalized.length) {
        final minBoundary = start + (chunkSize * 0.6).round();
        for (var index = end; index > minBoundary; index--) {
          final char = normalized[index - 1];
          if (char == '\n' ||
              char == '.' ||
              char == '!' ||
              char == '?' ||
              char == ';') {
            end = index;
            break;
          }
        }
      }

      final chunk = normalized.substring(start, end).trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      if (end >= normalized.length) break;
      start = math.max(end - overlap, start + 1);
    }
    return chunks;
  }
}

class WavAudio {
  const WavAudio({
    required this.sourceSampleRate,
    required this.sourceChannels,
    required this.samples,
  });

  final int sourceSampleRate;
  final int sourceChannels;
  final Float32List samples;

  static Future<WavAudio> read(File file) async {
    final bytes = await file.readAsBytes();
    if (bytes.length < 44) {
      throw const FormatException('Fichier WAV invalide.');
    }
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('Fichier WAV invalide.');
    }

    final data = ByteData.sublistView(bytes);
    int? format;
    int? channels;
    int? sampleRate;
    int? bitsPerSample;
    Uint8List? pcm;

    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (body + size > bytes.length) break;

      if (id == 'fmt ' && size >= 16) {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        sampleRate = data.getUint32(body + 4, Endian.little);
        bitsPerSample = data.getUint16(body + 14, Endian.little);
        if (format == 0xFFFE && size >= 40) {
          format = data.getUint16(body + 24, Endian.little);
        }
      } else if (id == 'data') {
        pcm = bytes.sublist(body, body + size);
      }

      offset = body + size + (size.isOdd ? 1 : 0);
    }

    if (format == null ||
        channels == null ||
        sampleRate == null ||
        bitsPerSample == null ||
        pcm == null) {
      throw const FormatException('Fichier WAV incomplet.');
    }
    if (format != 1 && format != 3) {
      throw const FormatException('Format WAV non pris en charge.');
    }

    final bytesPerSample = bitsPerSample ~/ 8;
    final frameBytes = bytesPerSample * channels;
    if (bytesPerSample == 0 || pcm.length < frameBytes) {
      throw const FormatException('Données WAV invalides.');
    }

    final frameCount = pcm.length ~/ frameBytes;
    final mono = Float32List(frameCount);
    final pcmData = ByteData.sublistView(pcm);
    for (var frame = 0; frame < frameCount; frame++) {
      var sum = 0.0;
      for (var channel = 0; channel < channels; channel++) {
        final index = frame * frameBytes + channel * bytesPerSample;
        sum += _sampleAt(pcmData, index, format, bitsPerSample);
      }
      mono[frame] = sum / channels;
    }

    return WavAudio(
      sourceSampleRate: sampleRate,
      sourceChannels: channels,
      samples: _resample(mono, sampleRate, AttachmentIngestor.audioSampleRate),
    );
  }

  static double _sampleAt(
    ByteData data,
    int index,
    int format,
    int bitsPerSample,
  ) {
    if (format == 3 && bitsPerSample == 32) {
      return data.getFloat32(index, Endian.little);
    }
    switch (bitsPerSample) {
      case 8:
        return (data.getUint8(index) - 128) / 128;
      case 16:
        return data.getInt16(index, Endian.little) / 32768;
      case 24:
        final value =
            data.getUint8(index) |
            (data.getUint8(index + 1) << 8) |
            (data.getUint8(index + 2) << 16);
        final signed = (value & 0x800000) != 0 ? value - 0x1000000 : value;
        return signed / 8388608;
      case 32:
        return data.getInt32(index, Endian.little) / 2147483648;
      default:
        throw const FormatException('Profondeur WAV non prise en charge.');
    }
  }

  static Float32List _resample(
    Float32List input,
    int sourceRate,
    int targetRate,
  ) {
    if (input.isEmpty || sourceRate == targetRate) return input;
    final outputLength = (input.length * targetRate / sourceRate).round();
    final output = Float32List(outputLength);
    final ratio = sourceRate / targetRate;
    for (var i = 0; i < outputLength; i++) {
      final position = i * ratio;
      final index = position.floor();
      final fraction = position - index;
      final firstIndex = math.min(math.max(index, 0), input.length - 1);
      final secondIndex = math.min(math.max(index + 1, 0), input.length - 1);
      final first = input[firstIndex];
      final second = input[secondIndex];
      output[i] = first + (second - first) * fraction;
    }
    return output;
  }
}
