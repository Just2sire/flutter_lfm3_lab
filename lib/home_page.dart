import 'package:flutter/material.dart';

import 'chat_page.dart';
import 'lfm3_model.dart';
import 'model_downloader.dart';

enum _ModelState { checking, missing, downloading, ready }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _downloader = ModelDownloader();

  _ModelState _state = _ModelState.checking;
  int _received = 0;
  int? _total;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkModel();
  }

  @override
  void dispose() {
    _downloader.close();
    super.dispose();
  }

  Future<void> _checkModel() async {
    try {
      final ready = await Lfm3Model.isReady();
      if (!mounted) return;
      setState(() {
        _state = ready ? _ModelState.ready : _ModelState.missing;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _ModelState.missing;
        _error = error.toString();
      });
    }
  }

  Future<void> _download() async {
    setState(() {
      _state = _ModelState.downloading;
      _received = 0;
      _total = null;
      _error = null;
    });

    try {
      await _downloader.download(
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _state = _ModelState.ready);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = _ModelState.missing;
        _error = error.toString();
      });
    }
  }

  Future<void> _handleModelInvalid() async {
    await Lfm3Model.delete();
    if (!mounted) return;
    setState(() {
      _state = _ModelState.missing;
      _error = null;
      _received = 0;
      _total = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return switch (_state) {
      _ModelState.ready => ChatPage(onModelInvalid: _handleModelInvalid),
      _ => _DownloadView(
        checking: _state == _ModelState.checking,
        downloading: _state == _ModelState.downloading,
        received: _received,
        total: _total,
        error: _error,
        onDownload: _download,
        onRetryCheck: _checkModel,
      ),
    };
  }
}

class _DownloadView extends StatelessWidget {
  const _DownloadView({
    required this.checking,
    required this.downloading,
    required this.received,
    required this.total,
    required this.error,
    required this.onDownload,
    required this.onRetryCheck,
  });

  final bool checking;
  final bool downloading;
  final int received;
  final int? total;
  final String? error;
  final VoidCallback onDownload;
  final VoidCallback onRetryCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = total != null && total! > 0 ? received / total! : null;

    return Scaffold(
      appBar: AppBar(title: const Text('LFM3 · local')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.memory,
                      size: 56,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'LFM3-1.7B sur votre appareil',
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Le modèle (Q4_K_M, environ 1,1 Go) est téléchargé '
                      'une seule fois. Une connexion Wi-Fi est recommandée.',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    const ListTile(
                      leading: Icon(Icons.lock_outline),
                      title: Text('100 % local'),
                      subtitle: Text(
                        'Le modèle et les conversations restent sur l’appareil.',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 16),
                    if (checking)
                      const Center(child: CircularProgressIndicator())
                    else if (downloading) ...[
                      LinearProgressIndicator(value: fraction),
                      const SizedBox(height: 12),
                      Text(
                        _progressLabel(received, total),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Gardez l’application ouverte pendant le téléchargement.',
                        textAlign: TextAlign.center,
                      ),
                    ] else ...[
                      FilledButton.icon(
                        onPressed: onDownload,
                        icon: const Icon(Icons.download),
                        label: const Text('Télécharger le modèle'),
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _progressLabel(int received, int? total) {
    final mb = (received / (1024 * 1024)).toStringAsFixed(1);
    if (total == null || total == 0) return '$mb Mo téléchargés';
    final totalMb = (total / (1024 * 1024)).toStringAsFixed(1);
    final percent = (received / total * 100).clamp(0, 100).toStringAsFixed(0);
    return '$mb / $totalMb Mo · $percent %';
  }
}
