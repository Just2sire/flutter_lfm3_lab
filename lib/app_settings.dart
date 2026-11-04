import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'lfm3_model.dart';

class AppSettings {
  const AppSettings({
    this.modelKind = Lfm3ModelKind.text,
    this.autoSpeak = false,
  });

  final Lfm3ModelKind modelKind;
  final bool autoSpeak;

  AppSettings copyWith({Lfm3ModelKind? modelKind, bool? autoSpeak}) {
    return AppSettings(
      modelKind: modelKind ?? this.modelKind,
      autoSpeak: autoSpeak ?? this.autoSpeak,
    );
  }

  Map<String, dynamic> toJson() => {
    'modelKind': modelKind.name,
    'autoSpeak': autoSpeak,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final rawKind = json['modelKind'];
    final kind = Lfm3ModelKind.values.firstWhere(
      (value) => value.name == rawKind,
      orElse: () => Lfm3ModelKind.text,
    );
    return AppSettings(
      modelKind: kind,
      autoSpeak: json['autoSpeak'] as bool? ?? false,
    );
  }
}

class SettingsStore {
  SettingsStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryProvider;

  Future<File> _file() async {
    final directory = await _directoryProvider();
    return File('${directory.path}/settings.json');
  }

  Future<AppSettings> load() async {
    final file = await _file();
    if (!await file.exists()) return const AppSettings();

    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map<String, dynamic>) {
        return AppSettings.fromJson(raw);
      }
      if (raw is Map) {
        return AppSettings.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (error) {
      debugPrint('SettingsStore load failed: $error');
    }

    return const AppSettings();
  }

  Future<void> save(AppSettings settings) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(settings.toJson()));
    try {
      await temp.rename(file.path);
    } on FileSystemException {
      await file.writeAsString(jsonEncode(settings.toJson()));
      if (await temp.exists()) await temp.delete();
    }
  }
}
