import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'conversation.dart';
import 'conversation_drawer.dart';
import 'conversation_store.dart';
import 'embedding_engine.dart';
import 'embedding_model.dart';
import 'lfm3_engine.dart';
import 'lfm3_model.dart';
import 'model_downloader.dart';
import 'rag.dart';
import 'rag_service.dart';
import 'speech_player.dart';

enum _ChatMenuAction { share, rename, newChat, about }

enum _AttachmentStatus { indexing, ready, error }

class _AttachmentEntry {
  _AttachmentEntry({
    required this.id,
    required this.name,
    required this.kind,
    this.status = _AttachmentStatus.indexing,
    this.attachment,
    this.statusText,
  });

  factory _AttachmentEntry.fromAttachment(RagAttachment attachment) {
    return _AttachmentEntry(
      id: attachment.id,
      name: attachment.name,
      kind: attachment.kind,
      status: _AttachmentStatus.ready,
      attachment: attachment,
    );
  }

  final String id;
  final String name;
  final RagAttachmentKind kind;
  _AttachmentStatus status;
  RagAttachment? attachment;
  String? error;
  String? statusText;
}

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.spec,
    required this.onModelInvalid,
    required this.onSwitchModel,
    required this.autoSpeak,
    required this.onAutoSpeakChanged,
  });

  final Lfm3ModelSpec spec;
  final Future<void> Function() onModelInvalid;
  final ValueChanged<Lfm3ModelKind> onSwitchModel;
  final bool autoSpeak;
  final ValueChanged<bool> onAutoSpeakChanged;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final Lfm3Engine _engine;
  late final AudioRecorder _recorder;
  late final RagService _rag;
  final _embedding = EmbeddingEngine();
  final _player = SpeechPlayer();
  final _store = ConversationStore();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _conversations = <Conversation>[];
  final _attachmentEntries = <_AttachmentEntry>[];

  Conversation? _active;
  late final AppLifecycleListener _lifecycle;

  bool _loading = true;
  bool _loadingModel = true;
  bool _generating = false;
  bool _stopRequested = false;
  bool _enableThinking = false;
  bool _showScrollButton = false;
  bool _recording = false;
  bool _transcribing = false;
  bool _synthesizing = false;
  bool _ragLoading = false;
  bool _downloadingEmbedding = false;
  int _embeddingReceived = 0;
  int _embeddingTotal = EmbeddingModel.spec.totalSizeBytes;
  int _speechToken = 0;
  int _playingToken = 0;
  late final StreamSubscription<void> _playbackComplete;
  int _recordSeconds = 0;
  String? _loadError;
  String? _generationError;
  String? _speakingMessageId;
  String _streamingText = '';
  DateTime? _streamStartedAt;
  DateTime? _recordStartedAt;
  Timer? _recordTimer;

  @override
  void initState() {
    super.initState();
    _engine = Lfm3Engine(spec: widget.spec);
    _recorder = AudioRecorder();
    _rag = RagService(embedding: _embedding);
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _playbackComplete = _player.onComplete.listen((_) {
      if (!mounted || _playingToken != _speechToken) return;
      setState(() {
        _synthesizing = false;
        _speakingMessageId = null;
      });
    });
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _recordTimer?.cancel();
    _playbackComplete.cancel();
    _scroll.removeListener(_onScroll);
    _engine.stop();
    unawaited(_engine.dispose());
    unawaited(_embedding.dispose());
    unawaited(_recorder.dispose());
    unawaited(_player.dispose());
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final state = await _store.load();
    if (!mounted) return;

    setState(() {
      _conversations
        ..clear()
        ..addAll(state.conversations);
      if (_conversations.isEmpty) {
        _conversations.add(Conversation.empty());
      }
      _active = _conversations.firstWhere(
        (conversation) => conversation.id == state.activeId,
        orElse: () => _conversations.first,
      );
      _loading = false;
    });

    unawaited(_persist());
    await _loadAttachments();
    await _loadModel(withHistory: _historyOf(_active).isNotEmpty);
  }

  Future<void> _loadAttachments() async {
    final conversation = _active;
    if (conversation == null) return;
    final index = await _rag.indexFor(conversation.id);
    if (!mounted) return;
    setState(() {
      _attachmentEntries
        ..clear()
        ..addAll(index.attachments.map(_AttachmentEntry.fromAttachment));
    });
  }

  bool get _indexingAttachment => _attachmentEntries.any(
    (entry) => entry.status == _AttachmentStatus.indexing,
  );

  Future<bool> _ensureEmbeddingModel({bool interactive = true}) async {
    if (_embedding.isLoaded) return true;
    if (_ragLoading) return false;

    if (!await EmbeddingModel.isReady()) {
      if (!interactive || !mounted) return false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Modèle de recherche requis'),
          content: Text(
            'EmbeddingGemma-2 (${_formatBytes(EmbeddingModel.spec.totalSizeBytes)}) '
            'doit être téléchargé pour indexer et rechercher dans les '
            'pièces jointes. Il reste sur cet appareil.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Télécharger'),
            ),
          ],
        ),
      );
      if (confirmed != true) return false;
      await _downloadEmbeddingModel();
      if (!await EmbeddingModel.isReady()) return false;
    }

    if (!mounted) return false;
    setState(() => _ragLoading = true);
    try {
      await _embedding.load();
      if (!mounted) return false;
      setState(() => _ragLoading = false);
      return true;
    } catch (error) {
      if (!mounted) return false;
      setState(() => _ragLoading = false);
      _showSnack('Modèle de recherche indisponible : ${_friendlyError(error)}');
      return false;
    }
  }

  Future<void> _downloadEmbeddingModel() async {
    if (_downloadingEmbedding) return;
    final downloader = ModelDownloader();
    setState(() {
      _downloadingEmbedding = true;
      _embeddingReceived = 0;
      _embeddingTotal = EmbeddingModel.spec.totalSizeBytes;
    });

    try {
      await downloader.downloadFiles(
        EmbeddingModel.spec.files,
        totalSizeBytes: EmbeddingModel.spec.totalSizeBytes,
        resolve: EmbeddingModel.fileOf,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _embeddingReceived = received;
            _embeddingTotal = total ?? EmbeddingModel.spec.totalSizeBytes;
          });
        },
      );
    } catch (error) {
      if (mounted) {
        _showSnack('Téléchargement échoué : ${_friendlyError(error)}');
      }
    } finally {
      downloader.close();
      if (mounted) setState(() => _downloadingEmbedding = false);
    }
  }

  Future<void> _pickAttachments() async {
    if (_downloadingEmbedding || _indexingAttachment || _generating) return;

    const group = XTypeGroup(
      label: 'Documents, images et audio',
      extensions: [
        'txt',
        'md',
        'markdown',
        'csv',
        'json',
        'log',
        'yaml',
        'yml',
        'xml',
        'html',
        'htm',
        'dart',
        'py',
        'js',
        'ts',
        'java',
        'kt',
        'c',
        'cpp',
        'h',
        'hpp',
        'rs',
        'go',
        'rb',
        'php',
        'sh',
        'sql',
        'ini',
        'toml',
        'png',
        'jpg',
        'jpeg',
        'webp',
        'bmp',
        'wav',
      ],
    );

    List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: const [group]);
    } catch (error) {
      if (mounted) _showSnack('Sélection de fichiers indisponible : $error');
      return;
    }
    if (files.isEmpty) return;

    final ready = await _ensureEmbeddingModel(interactive: true);
    if (!ready) return;

    for (final file in files) {
      if (!mounted) return;
      await _addAttachment(file);
    }
  }

  Future<void> _addAttachment(XFile file) async {
    final conversation = _active;
    if (conversation == null) return;

    final name = file.name.isEmpty ? p.basename(file.path) : file.name;
    final kind = ragKindForFileName(name);
    if (kind == null) {
      _showSnack('Format non pris en charge : $name');
      return;
    }

    final conversationId = conversation.id;
    final entry = _AttachmentEntry(
      id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      kind: kind,
      statusText: 'Indexation…',
    );
    setState(() => _attachmentEntries.add(entry));

    try {
      final attachment = await _rag.addFile(
        conversationId: conversationId,
        sourcePath: file.path,
        name: name,
        onStatus: (status) {
          if (!mounted) return;
          setState(() => entry.statusText = status);
        },
      );
      if (!mounted || _active?.id != conversationId) return;
      setState(() {
        entry.attachment = attachment;
        entry.status = _AttachmentStatus.ready;
        entry.statusText = null;
      });
      _showSnack('« $name » indexé (${attachment.chunkCount} extraits)');
    } catch (error) {
      if (!mounted || _active?.id != conversationId) return;
      setState(() {
        entry.status = _AttachmentStatus.error;
        entry.error = _friendlyError(error);
        entry.statusText = null;
      });
      _showSnack('Indexation impossible : ${_friendlyError(error)}');
    }
  }

  Future<void> _removeAttachment(_AttachmentEntry entry) async {
    final attachment = entry.attachment;
    final conversation = _active;
    if (attachment == null || conversation == null) return;
    try {
      await _rag.removeAttachment(conversation.id, attachment);
      if (!mounted) return;
      setState(() => _attachmentEntries.remove(entry));
    } catch (error) {
      if (mounted) {
        _showSnack('Suppression impossible : ${_friendlyError(error)}');
      }
    }
  }

  Future<String?> _searchContext(
    Conversation conversation,
    String prompt,
  ) async {
    if (!_attachmentEntries.any(
      (entry) => entry.status == _AttachmentStatus.ready,
    )) {
      return null;
    }

    if (!_embedding.isLoaded) {
      final ready = await _ensureEmbeddingModel(interactive: false);
      if (!ready) {
        if (mounted) {
          _showSnack(
            'Le modèle de recherche n’est pas chargé. '
            'Ajoutez une pièce jointe pour le télécharger.',
          );
        }
        return null;
      }
    }

    try {
      final results = await _rag.search(conversation.id, prompt);
      if (results.isEmpty) return null;

      final buffer = StringBuffer()
        ..writeln(
          'Contexte extrait des pièces jointes. Utilise-le pour répondre.',
        )
        ..writeln();
      for (final result in results) {
        final chunk = result.chunk;
        final text = chunk.text?.trim();
        if (text != null && text.isNotEmpty) {
          buffer.writeln('[${chunk.sourceName}]');
          buffer.writeln(text);
          buffer.writeln();
        } else {
          buffer.writeln('[${chunk.sourceName} — ${chunk.kind.name}]');
          buffer.writeln(
            'Pièce jointe non textuelle : le modèle texte ne peut pas '
            'lire son contenu directement.',
          );
          buffer.writeln();
        }
        if (buffer.length > 2800) break;
      }
      return buffer.toString().trim();
    } catch (error) {
      if (mounted) {
        _showSnack(
          'Recherche dans les pièces jointes indisponible : '
          '${_friendlyError(error)}',
        );
      }
      return null;
    }
  }

  List<ChatTurn> _historyOf(Conversation? conversation) => [
    if (conversation != null)
      for (final message in conversation.messages)
        ChatTurn(fromUser: message.fromUser, text: message.text),
  ];

  Future<void> _loadModel({bool withHistory = false}) async {
    setState(() {
      _loadingModel = true;
      _loadError = null;
    });

    try {
      await _engine.load(
        history: withHistory ? _historyOf(_active) : const <ChatTurn>[],
      );
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
      unawaited(_unloadModel());
    } else if (state == AppLifecycleState.resumed &&
        !_engine.isLoaded &&
        !_loadingModel &&
        _loadError == null) {
      unawaited(_loadModel(withHistory: _historyOf(_active).isNotEmpty));
    }
  }

  Future<void> _unloadModel() async {
    _engine.stop();
    if (_engine.isLoaded) await _engine.dispose();
    await _embedding.dispose();
  }

  Future<void> _persist() {
    return _store.save(
      ConversationState(
        conversations: List.of(_conversations),
        activeId: _active?.id,
      ),
    );
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    final conversation = _active;
    if (text.isEmpty ||
        conversation == null ||
        _generating ||
        _loadingModel ||
        _loadError != null) {
      return;
    }

    _input.clear();
    setState(() {
      conversation.messages.add(ChatMessage.user(text));
      if (conversation.title == Conversation.defaultTitle) {
        conversation.title = _titleFrom(text);
      }
      conversation.updatedAt = DateTime.now();
      _generationError = null;
    });
    unawaited(_persist());
    _scrollToBottom(force: true);

    await _runGeneration(conversation, text);
  }

  Future<void> _regenerate() async {
    final conversation = _active;
    if (conversation == null ||
        conversation.messages.isEmpty ||
        _generating ||
        _loadingModel ||
        _loadError != null) {
      return;
    }

    final messages = conversation.messages;
    final lastUserIndex = messages.lastIndexWhere(
      (message) => message.fromUser,
    );
    if (lastUserIndex < 0) return;

    if (lastUserIndex < messages.length - 1) {
      messages.removeRange(lastUserIndex + 1, messages.length);
    }

    final prompt = messages[lastUserIndex].text;
    final history = <ChatTurn>[
      for (var i = 0; i < lastUserIndex; i++)
        ChatTurn(fromUser: messages[i].fromUser, text: messages[i].text),
    ];

    setState(() {
      conversation.updatedAt = DateTime.now();
      _generationError = null;
    });
    _engine.setHistory(history);
    unawaited(_persist());

    await _runGeneration(conversation, prompt);
  }

  Future<void> _runGeneration(Conversation conversation, String prompt) async {
    await _stopSpeaking();
    if (!mounted) return;

    setState(() {
      _generating = true;
      _stopRequested = false;
      _generationError = null;
      _streamingText = '';
      _streamStartedAt = DateTime.now();
    });
    _scrollToBottom(force: true);

    try {
      final context = await _searchContext(conversation, prompt);
      if (!mounted) return;
      await for (final chunk in _engine.chat(
        prompt,
        enableThinking: _enableThinking,
        context: context,
      )) {
        if (!mounted) return;
        setState(() => _streamingText += chunk);
        _scrollToBottom();
      }

      if (!mounted) return;
      final reply = _streamingText.trim();
      final startedAt = _streamStartedAt;
      final elapsedMs = startedAt == null
          ? null
          : DateTime.now().difference(startedAt).inMilliseconds;

      ChatMessage? assistantMessage;
      setState(() {
        if (reply.isNotEmpty) {
          assistantMessage = ChatMessage.assistant(reply, elapsedMs: elapsedMs);
          conversation.messages.add(assistantMessage!);
          conversation.updatedAt = DateTime.now();
        }
        _generating = false;
        _stopRequested = false;
        _streamingText = '';
        _streamStartedAt = null;
      });
      unawaited(_persist());
      if (reply.isNotEmpty) _scrollToBottom();

      if (assistantMessage != null && widget.autoSpeak && widget.spec.isAudio) {
        unawaited(
          _speak(assistantMessage!.text, messageId: assistantMessage!.id),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _stopRequested = false;
        _streamingText = '';
        _streamStartedAt = null;
        _generationError = _friendlyError(error);
      });
    }
  }

  void _stop() {
    if (_generating && !_stopRequested) {
      setState(() => _stopRequested = true);
      _engine.stop();
    }
    if (_synthesizing || _speakingMessageId != null) {
      unawaited(_stopSpeaking());
    }
  }

  Future<void> _toggleRecording() async {
    if (!widget.spec.isAudio || _transcribing || _generating) return;
    if (_recording) {
      await _finishRecording();
      return;
    }

    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) _showSnack('Accès au micro refusé');
        return;
      }

      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}/lfm3_rec_'
          '${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );

      if (!mounted) return;
      setState(() {
        _recording = true;
        _recordStartedAt = DateTime.now();
        _recordSeconds = 0;
      });

      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final startedAt = _recordStartedAt;
        if (!mounted || startedAt == null) return;
        setState(() {
          _recordSeconds = DateTime.now().difference(startedAt).inSeconds;
        });
      });
    } catch (error) {
      if (mounted) _showSnack('Micro indisponible : $error');
    }
  }

  Future<void> _finishRecording() async {
    _recordTimer?.cancel();
    _recordTimer = null;

    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }

    if (!mounted) return;
    setState(() {
      _recording = false;
      _recordStartedAt = null;
      _recordSeconds = 0;
      _transcribing = path != null;
    });

    if (path == null) {
      _showSnack('Aucun enregistrement');
      return;
    }

    try {
      final transcript = await _engine.transcribe(path, language: 'French');
      if (!mounted) return;
      if (transcript.isEmpty) {
        _showSnack('Transcription vide');
      } else {
        setState(() {
          _input.text = transcript;
          _input.selection = TextSelection.collapsed(offset: transcript.length);
        });
      }
    } catch (error) {
      if (mounted) _showSnack(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _transcribing = false);
      try {
        await File(path).delete();
      } catch (_) {
        // Ignore cleanup errors.
      }
    }
  }

  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    _recordTimer = null;
    try {
      final path = await _recorder.stop();
      if (path != null) await File(path).delete();
    } catch (_) {
      // Ignore cancellation errors.
    }
    if (!mounted) return;
    setState(() {
      _recording = false;
      _recordStartedAt = null;
      _recordSeconds = 0;
    });
  }

  Future<void> _speak(String text, {String? messageId}) async {
    if (!widget.spec.isAudio ||
        text.trim().isEmpty ||
        _generating ||
        _transcribing ||
        _recording) {
      return;
    }

    await _stopSpeaking();
    if (!mounted) return;

    final token = ++_speechToken;
    setState(() {
      _synthesizing = true;
      _speakingMessageId = messageId;
    });

    try {
      final wav = await _engine.synthesize(text, language: 'fr');
      if (!mounted || token != _speechToken) return;

      _playingToken = token;
      setState(() => _synthesizing = false);
      await _player.play(wav);
    } catch (error) {
      if (mounted && token == _speechToken) {
        _showSnack('Lecture vocale indisponible : $error');
        setState(() {
          _synthesizing = false;
          _speakingMessageId = null;
        });
      }
    }
  }

  Future<void> _stopSpeaking() async {
    _speechToken++;
    _playingToken = 0;
    _engine.stopSpeech();
    try {
      await _player.stop();
    } catch (_) {
      // The player may not be initialized yet.
    }
    if (mounted) {
      setState(() {
        _synthesizing = false;
        _speakingMessageId = null;
      });
    }
  }

  void _newConversation() {
    final active = _active;
    if (active != null && active.messages.isEmpty) return;

    unawaited(_stopSpeaking());
    _engine.stop();
    final conversation = Conversation.empty();
    setState(() {
      _conversations.add(conversation);
      _active = conversation;
      _streamingText = '';
      _generationError = null;
      _stopRequested = false;
      _generating = false;
      _streamStartedAt = null;
      _attachmentEntries.clear();
    });
    if (_engine.isLoaded) _engine.setHistory(const <ChatTurn>[]);
    unawaited(_persist());
  }

  void _selectConversation(Conversation conversation) {
    if (conversation.id == _active?.id) {
      Navigator.of(context).maybePop();
      return;
    }

    unawaited(_stopSpeaking());
    _engine.stop();
    setState(() {
      _active = conversation;
      _streamingText = '';
      _generationError = null;
      _stopRequested = false;
      _generating = false;
      _streamStartedAt = null;
    });
    if (_engine.isLoaded) _engine.setHistory(_historyOf(conversation));
    unawaited(_loadAttachments());
    unawaited(_persist());
    _scrollToBottom(force: true);
    Navigator.of(context).maybePop();
  }

  Future<void> _renameConversation(Conversation conversation) async {
    final controller = TextEditingController(text: conversation.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Renommer la conversation'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.of(context).pop(value),
          decoration: const InputDecoration(hintText: 'Titre'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Renommer'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted) return;
    final title = result?.trim();
    if (title == null || title.isEmpty) return;

    setState(() {
      conversation.title = title;
      conversation.updatedAt = DateTime.now();
    });
    unawaited(_persist());
  }

  Future<void> _deleteConversation(Conversation conversation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer la conversation ?'),
        content: Text(
          '« ${conversation.title} » et ses messages seront définitivement '
          'supprimés de cet appareil.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    unawaited(_stopSpeaking());
    _engine.stop();
    setState(() {
      _conversations.removeWhere((item) => item.id == conversation.id);
      if (_active?.id == conversation.id) {
        if (_conversations.isEmpty) {
          _conversations.add(Conversation.empty());
        }
        _active = _conversations.first;
        _streamingText = '';
        _generationError = null;
        _stopRequested = false;
        _generating = false;
        _streamStartedAt = null;
      }
    });
    if (_engine.isLoaded) _engine.setHistory(_historyOf(_active));
    unawaited(_rag.deleteConversation(conversation.id));
    unawaited(_loadAttachments());
    unawaited(_persist());
  }

  void _deleteMessage(ChatMessage message) {
    final conversation = _active;
    if (conversation == null || _generating) return;

    if (_speakingMessageId == message.id) unawaited(_stopSpeaking());
    setState(() {
      conversation.messages.removeWhere((item) => item.id == message.id);
      conversation.updatedAt = DateTime.now();
    });
    if (_engine.isLoaded) _engine.setHistory(_historyOf(conversation));
    unawaited(_persist());
  }

  Future<void> _copyText(String text, {String label = 'Copié'}) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _showSnack(label);
  }

  Future<void> _share(String text, {String? subject}) async {
    if (text.trim().isEmpty) return;
    try {
      await SharePlus.instance.share(
        ShareParams(text: text, subject: subject, title: subject),
      );
    } catch (_) {
      await _copyText(text, label: 'Partage indisponible, texte copié');
    }
  }

  Future<void> _shareConversation(Conversation conversation) async {
    if (conversation.messages.isEmpty) return;
    await _share(_transcript(conversation), subject: conversation.title);
  }

  Future<void> _openLink(String url, String title) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) _showSnack('Impossible d’ouvrir le lien');
    } catch (_) {
      if (mounted) _showSnack('Impossible d’ouvrir le lien');
    }
  }

  void _showSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final show = position.pixels < position.maxScrollExtent - 160;
    if (show != _showScrollButton) {
      setState(() => _showScrollButton = show);
    }
  }

  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (!force && _showScrollButton) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  String _titleFrom(String text) {
    final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (single.isEmpty) return Conversation.defaultTitle;
    return single.length > 48 ? '${single.substring(0, 48)}…' : single;
  }

  String _transcript(Conversation conversation) {
    final buffer = StringBuffer()
      ..writeln(conversation.title)
      ..writeln();
    for (final message in conversation.messages) {
      buffer.writeln(message.fromUser ? 'Vous :' : 'LFM3 :');
      buffer.writeln(message.text);
      buffer.writeln();
    }
    buffer.writeln('— LFM3-1.7B · 100 % local');
    return buffer.toString().trim();
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
    if (text.contains('Projecteur audio introuvable')) {
      return 'Le projecteur audio est absent. Retéléchargez le modèle voix.';
    }
    if (text.contains('modèle d’embeddings est absent')) {
      return 'Le modèle de recherche est absent. Ajoutez une pièce jointe '
          'pour le télécharger.';
    }
    if (text.contains('Le modèle d’embeddings n’est pas chargé')) {
      return 'Le modèle de recherche n’est pas chargé.';
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
        onRetry: () => _loadModel(withHistory: _historyOf(_active).isNotEmpty),
        onDeleteModel: _deleteModel,
      );
    }

    if (_loading || _loadingModel) {
      return Scaffold(
        appBar: AppBar(title: const Text('LFM3 · local')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                _loading
                    ? 'Chargement des conversations…'
                    : 'Chargement du modèle…',
              ),
            ],
          ),
        ),
      );
    }

    final conversation = _active;
    if (conversation == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final messages = conversation.messages;

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _stop},
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            conversation.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (widget.spec.isAudio)
              IconButton(
                onPressed: () => widget.onAutoSpeakChanged(!widget.autoSpeak),
                icon: Icon(
                  widget.autoSpeak ? Icons.volume_up : Icons.volume_off,
                ),
                tooltip: widget.autoSpeak
                    ? 'Lecture auto activée'
                    : 'Lecture auto désactivée',
              ),
            IconButton(
              onPressed: () =>
                  setState(() => _enableThinking = !_enableThinking),
              icon: Icon(
                _enableThinking ? Icons.psychology : Icons.psychology_outlined,
              ),
              tooltip: _enableThinking
                  ? 'Réflexion activée'
                  : 'Réflexion désactivée',
            ),
            PopupMenuButton<_ChatMenuAction>(
              onSelected: _onMenu,
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _ChatMenuAction.share,
                  enabled: messages.isNotEmpty,
                  child: const ListTile(
                    leading: Icon(Icons.ios_share_outlined),
                    title: Text('Partager la conversation'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: _ChatMenuAction.rename,
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Renommer'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: _ChatMenuAction.newChat,
                  child: ListTile(
                    leading: Icon(Icons.add_comment_outlined),
                    title: Text('Nouveau chat'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: _ChatMenuAction.about,
                  child: ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('À propos'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ],
        ),
        drawer: ConversationDrawer(
          conversations: _conversations,
          activeId: conversation.id,
          modelKind: widget.spec.kind,
          onNewChat: () {
            Navigator.of(context).maybePop();
            _newConversation();
          },
          onSelect: _selectConversation,
          onRename: _renameConversation,
          onDelete: _deleteConversation,
          onSelectModel: widget.onSwitchModel,
          onAbout: () {
            Navigator.of(context).maybePop();
            _showAbout();
          },
        ),
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  if (messages.isEmpty && !_generating)
                    _EmptyChat(onSuggestion: (prompt) => _send(prompt))
                  else
                    SelectionArea(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                        itemCount: messages.length + (_generating ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index < messages.length) {
                            final message = messages[index];
                            final isLast = index == messages.length - 1;
                            return _MessageBubble(
                              fromUser: message.fromUser,
                              text: message.text,
                              createdAt: message.createdAt,
                              elapsedMs: message.elapsedMs,
                              onCopy: () => _copyText(message.text),
                              onShare: () => _share(
                                message.text,
                                subject: conversation.title,
                              ),
                              onDelete: _generating
                                  ? null
                                  : () => _deleteMessage(message),
                              onRegenerate:
                                  !_generating && !message.fromUser && isLast
                                  ? _regenerate
                                  : null,
                              onSpeak: widget.spec.isAudio && !message.fromUser
                                  ? () {
                                      if (_speakingMessageId == message.id) {
                                        unawaited(_stopSpeaking());
                                      } else {
                                        unawaited(
                                          _speak(
                                            message.text,
                                            messageId: message.id,
                                          ),
                                        );
                                      }
                                    }
                                  : null,
                              speaking: _speakingMessageId == message.id,
                              onLinkTap: _openLink,
                              onCodeCopy: (code) =>
                                  _copyText(code, label: 'Code copié'),
                            );
                          }

                          return _MessageBubble(
                            fromUser: false,
                            text: _streamingText,
                            pending: _streamingText.isEmpty,
                            stopped: _stopRequested,
                            streaming: true,
                            onLinkTap: _openLink,
                            onCodeCopy: (code) =>
                                _copyText(code, label: 'Code copié'),
                          );
                        },
                      ),
                    ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: _ScrollToBottomButton(
                      visible:
                          _showScrollButton &&
                          (messages.isNotEmpty || _generating),
                      onTap: () => _scrollToBottom(force: true),
                    ),
                  ),
                ],
              ),
            ),
            if (_generationError != null)
              _ErrorBanner(
                message: _generationError!,
                onClose: () => setState(() => _generationError = null),
              ),
            if (_recording || _transcribing || _synthesizing)
              _VoiceBanner(
                recording: _recording,
                transcribing: _transcribing,
                synthesizing: _synthesizing,
                seconds: _recordSeconds,
                onCancel: _recording
                    ? _cancelRecording
                    : (_synthesizing ? () => unawaited(_stopSpeaking()) : null),
              ),
            if (_downloadingEmbedding)
              _EmbeddingDownloadBanner(
                received: _embeddingReceived,
                total: _embeddingTotal,
              ),
            if (_ragLoading) const _RagLoadingBanner(),
            if (_attachmentEntries.isNotEmpty)
              _AttachmentBar(
                entries: _attachmentEntries,
                onRemove: (entry) => unawaited(_removeAttachment(entry)),
              ),
            _Composer(
              controller: _input,
              generating: _generating,
              stopRequested: _stopRequested,
              showMic: widget.spec.isAudio,
              recording: _recording,
              transcribing: _transcribing,
              onMic: _toggleRecording,
              onAttach: _pickAttachments,
              attaching: _downloadingEmbedding || _indexingAttachment,
              onSend: _send,
              onStop: _stop,
            ),
          ],
        ),
      ),
    );
  }

  void _onMenu(_ChatMenuAction action) {
    final conversation = _active;
    if (conversation == null) return;

    switch (action) {
      case _ChatMenuAction.share:
        unawaited(_shareConversation(conversation));
      case _ChatMenuAction.rename:
        unawaited(_renameConversation(conversation));
      case _ChatMenuAction.newChat:
        _newConversation();
      case _ChatMenuAction.about:
        _showAbout();
    }
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
    required this.fromUser,
    required this.text,
    this.createdAt,
    this.elapsedMs,
    this.pending = false,
    this.stopped = false,
    this.streaming = false,
    this.onCopy,
    this.onShare,
    this.onDelete,
    this.onRegenerate,
    this.onSpeak,
    this.speaking = false,
    this.onLinkTap,
    this.onCodeCopy,
  });

  final bool fromUser;
  final String text;
  final DateTime? createdAt;
  final int? elapsedMs;
  final bool pending;
  final bool stopped;
  final bool streaming;
  final VoidCallback? onCopy;
  final VoidCallback? onShare;
  final VoidCallback? onDelete;
  final VoidCallback? onRegenerate;
  final VoidCallback? onSpeak;
  final bool speaking;
  final void Function(String url, String title)? onLinkTap;
  final void Function(String code)? onCodeCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isUser = fromUser;

    final Widget content;
    if (pending) {
      content = stopped ? const Text('Arrêté.') : const _TypingDots();
    } else if (isUser) {
      content = Text(text);
    } else {
      content = GptMarkdown(
        text,
        isStreaming: streaming,
        onLinkTap: onLinkTap,
        onCodeCopy: onCodeCopy,
      );
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 640),
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? colors.primaryContainer
                    : colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              child: content,
            ),
            if (!streaming) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Wrap(
                  alignment: isUser ? WrapAlignment.end : WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (createdAt != null)
                      Text(
                        _formatTime(createdAt!),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    if (elapsedMs != null)
                      Text(
                        ' · ${_formatElapsed(elapsedMs!)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    if (onCopy != null)
                      _iconAction(Icons.copy_rounded, 'Copier', onCopy!),
                    if (onShare != null)
                      _iconAction(
                        Icons.ios_share_rounded,
                        'Partager',
                        onShare!,
                      ),
                    if (onSpeak != null)
                      _iconAction(
                        speaking ? Icons.stop_rounded : Icons.volume_up,
                        speaking ? 'Arrêter la lecture' : 'Lire à voix haute',
                        onSpeak!,
                      ),
                    if (onRegenerate != null)
                      _iconAction(Icons.refresh, 'Régénérer', onRegenerate!),
                    if (onDelete != null)
                      _iconAction(Icons.delete_outline, 'Supprimer', onDelete!),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _iconAction(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 4),
              Opacity(
                opacity:
                    0.3 +
                    0.7 *
                        (0.5 +
                            0.5 *
                                math.sin(
                                  _controller.value * 2 * math.pi - i * 0.6,
                                )),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const _suggestions = [
    'Explique-moi la photosynthèse simplement.',
    'Écris une fonction Dart qui inverse une chaîne.',
    'Donne-moi trois idées de repas rapides.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
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
            const SizedBox(height: 24),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final suggestion in _suggestions)
                  ActionChip(
                    avatar: const Icon(Icons.auto_awesome, size: 16),
                    label: Text(suggestion),
                    onPressed: () => onSuggestion(suggestion),
                  ),
              ],
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
    required this.showMic,
    required this.recording,
    required this.transcribing,
    required this.onMic,
    required this.onAttach,
    required this.attaching,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool generating;
  final bool stopRequested;
  final bool showMic;
  final bool recording;
  final bool transcribing;
  final VoidCallback onMic;
  final VoidCallback onAttach;
  final bool attaching;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              onPressed: generating || attaching ? null : onAttach,
              icon: attaching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.attach_file),
              tooltip: 'Ajouter des pièces jointes',
              visualDensity: VisualDensity.compact,
            ),
            if (showMic) ...[
              IconButton.filledTonal(
                onPressed: generating || transcribing ? null : onMic,
                icon: Icon(recording ? Icons.stop : Icons.mic),
                color: recording ? colors.error : null,
                tooltip: recording ? 'Arrêter la dictée' : 'Dicter un message',
              ),
              const SizedBox(width: 8),
            ],
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

class _AttachmentBar extends StatelessWidget {
  const _AttachmentBar({required this.entries, required this.onRemove});

  final List<_AttachmentEntry> entries;
  final ValueChanged<_AttachmentEntry> onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          Icon(Icons.attach_file, size: 16, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final entry in entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _AttachmentChip(
                        entry: entry,
                        onRemove: entry.status == _AttachmentStatus.indexing
                            ? null
                            : () => onRemove(entry),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.entry, this.onRemove});

  final _AttachmentEntry entry;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final Widget avatar;
    if (entry.status == _AttachmentStatus.indexing) {
      avatar = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (entry.status == _AttachmentStatus.error) {
      avatar = Icon(Icons.error_outline, size: 16, color: colors.error);
    } else {
      avatar = Icon(switch (entry.kind) {
        RagAttachmentKind.text => Icons.description_outlined,
        RagAttachmentKind.image => Icons.image_outlined,
        RagAttachmentKind.audio => Icons.audio_file_outlined,
      }, size: 16);
    }

    return Tooltip(
      message: entry.error ?? entry.statusText ?? entry.name,
      child: InputChip(
        avatar: avatar,
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        onDeleted: onRemove,
        deleteIcon: const Icon(Icons.close, size: 16),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _EmbeddingDownloadBanner extends StatelessWidget {
  const _EmbeddingDownloadBanner({required this.received, required this.total});

  final int received;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fraction = total > 0 ? (received / total).clamp(0.0, 1.0) : null;
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.downloading, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              const Expanded(child: Text('Téléchargement d’EmbeddingGemma-2…')),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: fraction),
          const SizedBox(height: 4),
          Text(
            '${_formatBytes(received)} / ${_formatBytes(total)}',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _RagLoadingBanner extends StatelessWidget {
  const _RagLoadingBanner();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Text('Chargement du modèle de recherche…')),
        ],
      ),
    );
  }
}

class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({required this.visible, required this.onTap});

  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: FloatingActionButton.small(
          onPressed: onTap,
          tooltip: 'Aller en bas',
          child: const Icon(Icons.arrow_downward),
        ),
      ),
    );
  }
}

class _VoiceBanner extends StatelessWidget {
  const _VoiceBanner({
    required this.recording,
    required this.transcribing,
    required this.synthesizing,
    required this.seconds,
    this.onCancel,
  });

  final bool recording;
  final bool transcribing;
  final bool synthesizing;
  final int seconds;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    final String label;
    final Widget leading;
    if (recording) {
      final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
      final secs = (seconds % 60).toString().padLeft(2, '0');
      label = 'Enregistrement… $minutes:$secs';
      leading = Icon(Icons.fiber_manual_record, color: colors.error, size: 18);
    } else if (transcribing) {
      label = 'Transcription en cours…';
      leading = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      label = 'Synthèse vocale…';
      leading = const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    return Container(
      width: double.infinity,
      color: colors.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          if (onCancel != null)
            TextButton(
              onPressed: onCancel,
              child: Text(recording ? 'Annuler' : 'Arrêter'),
            ),
        ],
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

String _formatTime(DateTime dateTime) {
  return '${dateTime.hour.toString().padLeft(2, '0')}:'
      '${dateTime.minute.toString().padLeft(2, '0')}';
}

String _formatElapsed(int milliseconds) {
  if (milliseconds < 1000) return '$milliseconds ms';
  return '${(milliseconds / 1000).toStringAsFixed(1)} s';
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} Go';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} Mo';
}
