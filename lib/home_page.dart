import 'dart:async';

import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'chat_page.dart';
import 'lfm3_model.dart';
import 'model_downloader.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.readyCheck, this.settingsStore});

  final Future<bool> Function(Lfm3ModelSpec spec)? readyCheck;
  final SettingsStore? settingsStore;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _downloader = ModelDownloader();
  late final SettingsStore _settings;

  final _ready = <Lfm3ModelKind, bool>{};
  Lfm3ModelKind _activeKind = Lfm3ModelKind.text;
  Lfm3ModelKind? _downloading;
  bool _checking = true;
  bool _autoSpeak = false;
  int _received = 0;
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _settings = widget.settingsStore ?? SettingsStore();
    _bootstrap();
  }

  @override
  void dispose() {
    _downloader.close();
    super.dispose();
  }

  Future<bool> _checkReady(Lfm3ModelSpec spec) {
    return (widget.readyCheck ?? Lfm3Model.isReady)(spec);
  }

  Future<void> _bootstrap() async {
    setState(() {
      _checking = true;
      _error = null;
    });

    try {
      final settings = await _settings.load();
      final ready = <Lfm3ModelKind, bool>{};
      for (final spec in Lfm3Model.all) {
        ready[spec.kind] = await _checkReady(spec);
      }
      if (!mounted) return;

      var activeKind = settings.modelKind;
      if (ready[activeKind] != true) {
        activeKind = Lfm3Model.all
            .firstWhere(
              (spec) => ready[spec.kind] == true,
              orElse: () => Lfm3Model.byKind(settings.modelKind),
            )
            .kind;
      }

      setState(() {
        _ready
          ..clear()
          ..addAll(ready);
        _activeKind = activeKind;
        _autoSpeak = settings.autoSpeak;
        _checking = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _saveSettings() {
    return _settings.save(
      AppSettings(modelKind: _activeKind, autoSpeak: _autoSpeak),
    );
  }

  void _switchModel(Lfm3ModelKind kind) {
    if (_activeKind == kind) return;
    setState(() {
      _activeKind = kind;
      _error = null;
    });
    unawaited(_saveSettings());
  }

  void _setAutoSpeak(bool value) {
    setState(() => _autoSpeak = value);
    unawaited(_saveSettings());
  }

  Future<void> _download(Lfm3ModelKind kind) async {
    final spec = Lfm3Model.byKind(kind);
    setState(() {
      _activeKind = kind;
      _downloading = kind;
      _received = 0;
      _total = spec.totalSizeBytes;
      _error = null;
    });

    try {
      await _downloader.download(
        spec,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total ?? spec.totalSizeBytes;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _ready[kind] = true;
        _downloading = null;
      });
      unawaited(_saveSettings());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _downloading = null;
        _error = error.toString();
      });
    }
  }

  Future<void> _handleModelInvalid() async {
    final spec = Lfm3Model.byKind(_activeKind);
    await Lfm3Model.delete(spec);
    if (!mounted) return;
    setState(() {
      _ready[_activeKind] = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Vérification des modèles…'),
            ],
          ),
        ),
      );
    }

    final activeSpec = Lfm3Model.byKind(_activeKind);
    if (_ready[_activeKind] == true) {
      return ChatPage(
        key: ValueKey(_activeKind),
        spec: activeSpec,
        autoSpeak: _autoSpeak,
        onAutoSpeakChanged: _setAutoSpeak,
        onSwitchModel: _switchModel,
        onModelInvalid: _handleModelInvalid,
      );
    }

    return _DownloadView(
      specs: Lfm3Model.all,
      ready: _ready,
      activeKind: _activeKind,
      downloading: _downloading,
      received: _received,
      total: _total,
      error: _error,
      onSelect: _switchModel,
      onDownload: _download,
      onRetryCheck: _bootstrap,
    );
  }
}

class _DownloadView extends StatelessWidget {
  const _DownloadView({
    required this.specs,
    required this.ready,
    required this.activeKind,
    required this.downloading,
    required this.received,
    required this.total,
    required this.error,
    required this.onSelect,
    required this.onDownload,
    required this.onRetryCheck,
  });

  final List<Lfm3ModelSpec> specs;
  final Map<Lfm3ModelKind, bool> ready;
  final Lfm3ModelKind activeKind;
  final Lfm3ModelKind? downloading;
  final int received;
  final int total;
  final String? error;
  final ValueChanged<Lfm3ModelKind> onSelect;
  final ValueChanged<Lfm3ModelKind> onDownload;
  final VoidCallback onRetryCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('LFM3 · local')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.memory, size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(
                  'LFM3 sur votre appareil',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Choisissez un modèle. Les fichiers sont téléchargés une '
                  'seule fois et restent sur l’appareil.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                for (final spec in specs) ...[
                  _ModelCard(
                    spec: spec,
                    isReady: ready[spec.kind] == true,
                    selected: activeKind == spec.kind,
                    downloading: downloading == spec.kind,
                    received: received,
                    total: total,
                    onSelect: () => onSelect(spec.kind),
                    onDownload: () => onDownload(spec.kind),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 8),
                const ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('100 % local'),
                  subtitle: Text(
                    'Le modèle et les conversations restent sur l’appareil.',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: onRetryCheck,
                    child: const Text('Vérifier à nouveau'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.spec,
    required this.isReady,
    required this.selected,
    required this.downloading,
    required this.received,
    required this.total,
    required this.onSelect,
    required this.onDownload,
  });

  final Lfm3ModelSpec spec;
  final bool isReady;
  final bool selected;
  final bool downloading;
  final int received;
  final int total;
  final VoidCallback onSelect;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fraction = total > 0 ? (received / total).clamp(0.0, 1.0) : null;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  spec.isAudio ? Icons.graphic_eq : Icons.chat_bubble_outline,
                  color: colors.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(spec.label, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(spec.description, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                if (isReady)
                  Icon(Icons.check_circle, color: colors.primary)
                else
                  Text(
                    _formatBytes(spec.totalSizeBytes),
                    style: theme.textTheme.labelMedium,
                  ),
              ],
            ),
            if (downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: fraction),
              const SizedBox(height: 8),
              Text(
                _progressLabel(received, total),
                textAlign: TextAlign.center,
              ),
            ] else ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (isReady)
                    FilledButton.icon(
                      onPressed: onSelect,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Ouvrir'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: onDownload,
                      icon: const Icon(Icons.download),
                      label: const Text('Télécharger'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} Go';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} Mo';
  }

  static String _progressLabel(int received, int total) {
    final mb = (received / (1024 * 1024)).toStringAsFixed(0);
    if (total <= 0) return '$mb Mo téléchargés';
    final totalMb = (total / (1024 * 1024)).toStringAsFixed(0);
    final percent = (received / total * 100).clamp(0, 100).toStringAsFixed(0);
    return '$mb / $totalMb Mo · $percent %';
  }
}
