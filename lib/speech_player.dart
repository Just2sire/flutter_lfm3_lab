import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// Plays synthesized WAV audio on mobile via `just_audio` and on desktop via
/// the system player, so Linux/Windows builds do not require GStreamer.
class SpeechPlayer {
  SpeechPlayer() {
    final player = _usesJustAudio ? AudioPlayer() : null;
    _player = player;
    _stateSub = player?.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) return;
      unawaited(_cleanup());
      if (!_complete.isClosed) _complete.add(null);
    });
  }

  static bool get _usesJustAudio =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  final _complete = StreamController<void>.broadcast();
  AudioPlayer? _player;
  StreamSubscription<ProcessingState>? _stateSub;
  Process? _process;
  String? _tempPath;

  Stream<void> get onComplete => _complete.stream;

  Future<void> play(Uint8List wav) async {
    await stop();
    final path = await _writeTemp(wav);
    _tempPath = path;
    final player = _player;
    if (player != null) {
      await player.setFilePath(path);
      await player.play();
      return;
    }
    await _playWithSystemPlayer(path);
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    process?.kill();
    await _player?.stop();
    await _cleanup();
  }

  Future<void> dispose() async {
    await stop();
    await _stateSub?.cancel();
    await _player?.dispose();
    await _complete.close();
  }

  Future<String> _writeTemp(Uint8List wav) async {
    final directory = await getTemporaryDirectory();
    final path =
        '${directory.path}/lfm3_tts_'
        '${DateTime.now().microsecondsSinceEpoch}.wav';
    await File(path).writeAsBytes(wav, flush: true);
    return path;
  }

  Future<void> _playWithSystemPlayer(String path) async {
    final Process process;
    if (Platform.isLinux) {
      final command = await _firstAvailable(const ['paplay', 'aplay']);
      if (command == null) {
        throw StateError('Aucun lecteur audio système (paplay/aplay) trouvé.');
      }
      process = await Process.start(command, [path]);
    } else if (Platform.isWindows) {
      final escaped = path.replaceAll("'", "''");
      process = await Process.start('powershell', [
        '-NoProfile',
        '-Command',
        "(New-Object Media.SoundPlayer '$escaped').PlaySync()",
      ]);
    } else {
      throw UnsupportedError(
        'Lecture audio non prise en charge sur cette plateforme.',
      );
    }
    _process = process;
    unawaited(
      process.exitCode.then((_) {
        if (!identical(_process, process)) return;
        _process = null;
        unawaited(_cleanup());
        if (!_complete.isClosed) _complete.add(null);
      }),
    );
  }

  Future<String?> _firstAvailable(List<String> names) async {
    for (final name in names) {
      final result = await Process.run('which', [name]);
      if (result.exitCode == 0) return name;
    }
    return null;
  }

  Future<void> _cleanup() async {
    final path = _tempPath;
    _tempPath = null;
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {
      // Ignore cleanup errors.
    }
  }
}
