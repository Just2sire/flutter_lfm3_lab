import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum RagAttachmentKind { text, image, audio }

RagAttachmentKind? ragKindForFileName(String name) {
  final extension = p.extension(name).toLowerCase();
  if (const {
    '.txt',
    '.md',
    '.markdown',
    '.csv',
    '.json',
    '.log',
    '.yaml',
    '.yml',
    '.xml',
    '.html',
    '.htm',
    '.dart',
    '.py',
    '.js',
    '.ts',
    '.java',
    '.kt',
    '.c',
    '.cpp',
    '.h',
    '.hpp',
    '.rs',
    '.go',
    '.rb',
    '.php',
    '.sh',
    '.sql',
    '.ini',
    '.toml',
  }.contains(extension)) {
    return RagAttachmentKind.text;
  }
  if (const {'.png', '.jpg', '.jpeg', '.webp', '.bmp'}.contains(extension)) {
    return RagAttachmentKind.image;
  }
  if (extension == '.wav') return RagAttachmentKind.audio;
  return null;
}

class RagAttachment {
  const RagAttachment({
    required this.id,
    required this.name,
    required this.kind,
    required this.path,
    required this.sizeBytes,
    required this.chunkCount,
    required this.createdAt,
  });

  final String id;
  final String name;
  final RagAttachmentKind kind;
  final String path;
  final int sizeBytes;
  final int chunkCount;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'path': path,
    'sizeBytes': sizeBytes,
    'chunkCount': chunkCount,
    'createdAt': createdAt.toIso8601String(),
  };

  factory RagAttachment.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String?;
    final kind = RagAttachmentKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => RagAttachmentKind.text,
    );
    return RagAttachment(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Pièce jointe',
      kind: kind,
      path: json['path'] as String? ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      chunkCount: (json['chunkCount'] as num?)?.toInt() ?? 0,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class RagChunk {
  const RagChunk({
    required this.id,
    required this.attachmentId,
    required this.sourceName,
    required this.kind,
    required this.vector,
    this.text,
    this.path,
    this.startSample,
    this.endSample,
  });

  final String id;
  final String attachmentId;
  final String sourceName;
  final RagAttachmentKind kind;
  final List<double> vector;
  final String? text;
  final String? path;
  final int? startSample;
  final int? endSample;

  Map<String, dynamic> toJson() => {
    'id': id,
    'attachmentId': attachmentId,
    'sourceName': sourceName,
    'kind': kind.name,
    'vector': _encodeVector(vector),
    if (text != null) 'text': text,
    if (path != null) 'path': path,
    if (startSample != null) 'startSample': startSample,
    if (endSample != null) 'endSample': endSample,
  };

  factory RagChunk.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String?;
    final kind = RagAttachmentKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => RagAttachmentKind.text,
    );
    return RagChunk(
      id: json['id'] as String? ?? '',
      attachmentId: json['attachmentId'] as String? ?? '',
      sourceName: json['sourceName'] as String? ?? 'Pièce jointe',
      kind: kind,
      vector: _decodeVector(json['vector'] as String? ?? ''),
      text: json['text'] as String?,
      path: json['path'] as String?,
      startSample: (json['startSample'] as num?)?.toInt(),
      endSample: (json['endSample'] as num?)?.toInt(),
    );
  }
}

class RagIndex {
  RagIndex({List<RagAttachment>? attachments, List<RagChunk>? chunks})
    : attachments = attachments ?? [],
      chunks = chunks ?? [];

  final List<RagAttachment> attachments;
  final List<RagChunk> chunks;

  bool get isEmpty => attachments.isEmpty;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'attachments': [for (final attachment in attachments) attachment.toJson()],
    'chunks': [for (final chunk in chunks) chunk.toJson()],
  };

  factory RagIndex.fromJson(Map<String, dynamic> json) {
    final attachments = <RagAttachment>[];
    final rawAttachments = json['attachments'];
    if (rawAttachments is List) {
      for (final raw in rawAttachments) {
        if (raw is Map) {
          attachments.add(
            RagAttachment.fromJson(Map<String, dynamic>.from(raw)),
          );
        }
      }
    }

    final chunks = <RagChunk>[];
    final rawChunks = json['chunks'];
    if (rawChunks is List) {
      for (final raw in rawChunks) {
        if (raw is Map) {
          final chunk = RagChunk.fromJson(Map<String, dynamic>.from(raw));
          if (chunk.vector.isNotEmpty) chunks.add(chunk);
        }
      }
    }

    return RagIndex(attachments: attachments, chunks: chunks);
  }
}

class AttachmentStore {
  AttachmentStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<Directory> _root() async {
    final support = await _directoryProvider();
    return Directory(p.join(support.path, 'rag'));
  }

  Future<Directory> _conversationDir(String conversationId) async {
    final root = await _root();
    return Directory(p.join(root.path, _safeId(conversationId)));
  }

  Future<File> _indexFile(String conversationId) async {
    final directory = await _conversationDir(conversationId);
    return File(p.join(directory.path, 'index.json'));
  }

  Future<RagIndex> load(String conversationId) async {
    final file = await _indexFile(conversationId);
    if (!await file.exists()) return RagIndex();
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map) {
        return RagIndex.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (error) {
      developer.log('AttachmentStore load failed: $error');
    }
    return RagIndex();
  }

  Future<void> save(String conversationId, RagIndex index) async {
    final file = await _indexFile(conversationId);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(index.toJson()));
    try {
      await temp.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(jsonEncode(index.toJson()));
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<String> importFile({
    required String conversationId,
    required String sourcePath,
    required String name,
  }) async {
    final directory = await _conversationDir(conversationId);
    await directory.create(recursive: true);
    final id = _newId();
    final fileName = '${id}_${_safeFileName(name)}';
    final destination = File(p.join(directory.path, fileName));
    await File(sourcePath).copy(destination.path);
    return destination.path;
  }

  Future<void> deleteAttachment(RagAttachment attachment) async {
    final file = File(attachment.path);
    if (await file.exists()) await file.delete();
  }

  Future<void> deleteConversation(String conversationId) async {
    final directory = await _conversationDir(conversationId);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static int _counter = 0;

  static String _newId() {
    _counter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_counter';
  }

  static String _safeId(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.isEmpty ? 'conversation' : safe;
  }

  static String _safeFileName(String value) {
    final base = p.basename(value);
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.isEmpty ? 'attachment' : safe;
  }
}

String _encodeVector(List<double> vector) {
  final bytes = Uint8List(vector.length * 4);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < vector.length; i++) {
    data.setFloat32(i * 4, vector[i], Endian.little);
  }
  return base64Encode(bytes);
}

List<double> _decodeVector(String value) {
  if (value.isEmpty) return const [];
  try {
    final bytes = base64Decode(value);
    if (bytes.length % 4 != 0) return const [];
    final data = ByteData.sublistView(bytes);
    return [
      for (var i = 0; i < bytes.length ~/ 4; i++)
        data.getFloat32(i * 4, Endian.little),
    ];
  } catch (_) {
    return const [];
  }
}
