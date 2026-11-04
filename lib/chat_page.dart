import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'lfm3_engine.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.onModelInvalid});

  final Future<void> Function() onModelInvalid;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatMessage {
  _ChatMessage({required this.fromUser, required this.text});

  final bool fromUser;
  String text;
}

class _ChatPageState extends State<ChatPage> {
  final _engine = Lfm3Engine();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <_ChatMessage>[];

  late final AppLifecycleListener _lifecycle;

  bool _loadingModel = true;
  bool _generating = false;
  bool _stopRequested = false;
  bool _enableThinking = false;
  String? _loadError;
  String? _generationError;
  String _streamingText = '';

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _loadModel();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _engine.stop();
    unawaited(_engine.dispose());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadModel({bool withHistory = false}) async {
    setState(() {
      _loadingModel = true;
      _loadError = null;
    });

    try {
      final history = withHistory
          ? [
              for (final message in _messages)
                ChatTurn(fromUser: message.fromUser, text: message.text),
            ]
          : const <ChatTurn>[];
      await _engine.load(history: history);
      if (!mounted) return;
      setState(() => _loadingModel = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingModel = false;
        _loadError = _friendlyError(error);
      });
    }
  }

  void _onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _unloadModel();
    } else if (state == AppLifecycleState.resumed &&
        !_engine.isLoaded &&
        !_loadingModel &&
        _loadError == null) {
      unawaited(_loadModel(withHistory: _messages.isNotEmpty));
    }
  }

  Future<void> _unloadModel() async {
    if (!_engine.isLoaded) return;
    _engine.stop();
    await _engine.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _generating || _loadingModel || _loadError != null) {
      return;
    }

    _input.clear();
    setState(() {
      _messages.add(_ChatMessage(fromUser: true, text: text));
      _generating = true;
      _stopRequested = false;
      _generationError = null;
      _streamingText = '';
    });
    _scrollToBottom();

    try {
      await for (final chunk in _engine.chat(
        text,
        enableThinking: _enableThinking,
      )) {
        if (!mounted) return;
        setState(() => _streamingText += chunk);
        _scrollToBottom();
      }

      if (!mounted) return;
      final reply = _streamingText.trim();
      setState(() {
        if (reply.isNotEmpty) {
          _messages.add(_ChatMessage(fromUser: false, text: reply));
        }
        _generating = false;
        _stopRequested = false;
        _streamingText = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _stopRequested = false;
        _streamingText = '';
        _generationError = _friendlyError(error);
      });
    }
  }

  void _stop() {
    if (!_generating || _stopRequested) return;
    setState(() => _stopRequested = true);
    _engine.stop();
  }

  void _newConversation() {
    _engine.stop();
    _engine.reset();
    setState(() {
      _messages.clear();
      _streamingText = '';
      _generationError = null;
      _stopRequested = false;
      _generating = false;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  String _friendlyError(Object error) {
    final text = error.toString();
    if (text.contains('out of memory') || text.contains('OOM')) {
      return 'Mémoire insuffisante pour charger le modèle. '
          'Fermez d’autres applications puis réessayez.';
    }
    if (text.contains('unknown model architecture')) {
      return 'Le moteur natif ne reconnaît pas l’architecture LFM3. '
          'Mettez llamadart à jour.';
    }
    if (text.contains('Modèle introuvable')) {
      return 'Le fichier du modèle est absent. Retéléchargez-le.';
    }
    return text;
  }

  Future<void> _deleteModel() async {
    await widget.onModelInvalid();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadError != null) {
      return _ErrorView(
        message: _loadError!,
        onRetry: () => _loadModel(withHistory: _messages.isNotEmpty),
        onDeleteModel: _deleteModel,
      );
    }

    if (_loadingModel) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Chargement du modèle…'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('LFM3 · local'),
        actions: [
          IconButton(
            onPressed: () => setState(() => _enableThinking = !_enableThinking),
            icon: Icon(
              _enableThinking ? Icons.psychology : Icons.psychology_outlined,
            ),
            tooltip: _enableThinking
                ? 'Réflexion activée'
                : 'Réflexion désactivée',
          ),
          IconButton(
            onPressed: _messages.isEmpty || _generating
                ? null
                : _newConversation,
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Nouvelle conversation',
          ),
          IconButton(
            onPressed: _showAbout,
            icon: const Icon(Icons.info_outline),
            tooltip: 'À propos',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty && !_generating
                ? const _EmptyChat()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length + (_generating ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index < _messages.length) {
                        return _MessageBubble(message: _messages[index]);
                      }
                      return _MessageBubble(
                        message: _ChatMessage(
                          fromUser: false,
                          text: _streamingText,
                        ),
                        pending: _streamingText.isEmpty,
                        stopped: _stopRequested,
                        streaming: true,
                      );
                    },
                  ),
          ),
          if (_generationError != null)
            _ErrorBanner(
              message: _generationError!,
              onClose: () => setState(() => _generationError = null),
            ),
          _Composer(
            controller: _input,
            generating: _generating,
            stopRequested: _stopRequested,
            onSend: _send,
            onStop: _stop,
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('LFM3 · 100 % local'),
        content: const Text(
          'Le modèle et vos conversations restent sur cet appareil. '
          'Aucune requête n’est envoyée à un serveur pendant le chat.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.pending = false,
    this.stopped = false,
    this.streaming = false,
  });

  final _ChatMessage message;
  final bool pending;
  final bool stopped;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isUser = message.fromUser;
    final text = message.text.isEmpty
        ? (stopped ? 'Arrêté.' : 'Le modèle réfléchit…')
        : message.text;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: pending
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(text),
                ],
              )
            : isUser
            ? Text(text)
            : GptMarkdown(text, isStreaming: streaming),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              'Posez une question à LFM3',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Le modèle tourne entièrement sur cet appareil. '
              'Vos échanges ne quittent pas l’appareil.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.generating,
    required this.stopRequested,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool generating;
  final bool stopRequested;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !generating,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Écrivez un message…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: generating ? (stopRequested ? null : onStop) : onSend,
              icon: Icon(
                generating
                    ? (stopRequested ? Icons.hourglass_top : Icons.stop)
                    : Icons.send,
              ),
              tooltip: generating ? 'Arrêter' : 'Envoyer',
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: colors.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.close, color: colors.onErrorContainer),
            tooltip: 'Fermer',
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.onRetry,
    required this.onDeleteModel,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDeleteModel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('LFM3 · local')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.memory, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Le modèle n’a pas pu être chargé.',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Réessayer'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: onDeleteModel,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Supprimer et retélécharger'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
