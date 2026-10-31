import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../widgets/common.dart';
import '../widgets/message_bubble.dart';
import 'profile_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.app, required this.conversation});
  final AppController app;
  final Conversation conversation;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _text = TextEditingController(), _search = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  List<Message> _messages = [];
  StreamSubscription<Json>? _subscription;
  Timer? _typingTimer, _outgoingTyping;
  bool _loading = true,
      _loadingOlder = false,
      _hasMore = false,
      _sending = false,
      _uploading = false,
      _typing = false,
      _searching = false,
      _foreground = true,
      _reading = false;
  String? _error, _draftID, _draftSignature, _readThrough;
  Message? _reply;
  Attachment? _attachment;
  Uint8List? _attachmentBytes;
  late ChatUser _peer;
  int _loadGeneration = 0;
  bool get _nearBottom => !_scroll.hasClients || _scroll.offset < 140;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _peer = widget.conversation.peer;
    _scroll.addListener(_onScroll);
    _text.addListener(_onText);
    _load();
    _subscription = widget.app.realtime.events.listen(_event);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _load();
    } else {
      widget.app.realtime.typing(widget.conversation.id, false);
    }
  }

  void _onScroll() {
    if (_nearBottom) _markRead();
  }

  void _onText() {
    setState(() {});
    widget.app.realtime.typing(
      widget.conversation.id,
      _text.text.trim().isNotEmpty,
    );
    _outgoingTyping?.cancel();
    _outgoingTyping = Timer(
      const Duration(seconds: 2),
      () => widget.app.realtime.typing(widget.conversation.id, false),
    );
  }

  void _event(Json event) {
    if (!mounted) return;
    if (event['type'] == 'ready') {
      _load();
      return;
    }
    if (event['type'] == 'presence' && event['user_id'] == _peer.id) {
      setState(() => _peer = _peer.withOnline(event['online']));
      return;
    }
    if (event['conversation_id'] != widget.conversation.id) return;
    switch (event['type']) {
      case 'message':
        final near = _nearBottom;
        final message = Message.fromJson(event['message']);
        setState(() {
          _upsert(message);
          if (message.senderId == _peer.id) _typing = false;
        });
        if (near) {
          _toBottom();
          _markRead();
        }
      case 'read':
        if (event['user_id'] != widget.app.user?.id) {
          final through = BigInt.parse(event['message_id']);
          setState(() {
            for (final m in _messages) {
              if (m.senderId == widget.app.user?.id &&
                  BigInt.parse(m.id) <= through) {
                m.isRead = true;
              }
            }
          });
        }
      case 'typing':
        if (event['user_id'] == _peer.id) {
          _typingTimer?.cancel();
          setState(() => _typing = event['typing']);
          _typingTimer = Timer(const Duration(seconds: 4), () {
            if (mounted) setState(() => _typing = false);
          });
        }
      case 'reaction':
        setState(() {
          for (final m in _messages.where((m) => m.id == event['message_id'])) {
            m.reactions.removeWhere((r) => r['user_id'] == event['user_id']);
            if (event['emoji'] != '') {
              m.reactions.add({
                'user_id': event['user_id'],
                'emoji': event['emoji'],
              });
            }
          }
        });
    }
  }

  void _upsert(Message message) {
    final index = _messages.indexWhere((m) => m.id == message.id);
    if (index < 0) {
      _messages.add(message);
    } else {
      _messages[index] = message;
    }
    _messages.sort((a, b) => BigInt.parse(a.id).compareTo(BigInt.parse(b.id)));
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final data = await widget.app.api.request(
        'GET',
        '/conversations/${widget.conversation.id}/messages',
      );
      if (!mounted || generation != _loadGeneration) return;
      final incoming = (data['messages'] as List)
          .map((j) => Message.fromJson(j))
          .toList();
      final newest = incoming.isEmpty
          ? BigInt.zero
          : BigInt.parse(incoming.last.id);
      final duringRequest = _messages
          .where((m) => BigInt.parse(m.id) > newest)
          .toList();
      final wasLoading = _loading;
      setState(() {
        _messages = incoming;
        for (final m in duringRequest) {
          _upsert(m);
        }
        _hasMore = data['has_more'];
        _loading = false;
        _error = null;
      });
      if (wasLoading || _nearBottom) _toBottom();
      _markRead();
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _older() async {
    if (_loadingOlder || _messages.isEmpty) return;
    setState(() => _loadingOlder = true);
    try {
      final data = await widget.app.api.request(
        'GET',
        '/conversations/${widget.conversation.id}/messages',
        query: {'before': _messages.first.id},
      );
      if (mounted) {
        setState(() {
          for (final j in data['messages']) {
            _upsert(Message.fromJson(j));
          }
          _hasMore = data['has_more'];
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _markRead() async {
    if (_reading ||
        _messages.isEmpty ||
        !_foreground ||
        !_nearBottom ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final id = _messages.last.id;
    if (_readThrough == id) return;
    _reading = true;
    try {
      await widget.app.api.request(
        'POST',
        '/conversations/${widget.conversation.id}/read',
        data: {'message_id': id},
      );
      _readThrough = id;
    } catch (_) {
      /* Retried after the next scroll or reconnect. */
    } finally {
      _reading = false;
      if (mounted &&
          _readThrough == id &&
          _messages.isNotEmpty &&
          _messages.last.id != id) {
        _markRead();
      }
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _setReply(Message m) {
    setState(() => _reply = m);
    _focus.requestFocus();
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (_sending || _uploading || (text.isEmpty && _attachment == null)) return;
    final signature = '$text|${_attachment?.id}|${_reply?.id}';
    if (_draftSignature != signature) {
      _draftID = const Uuid().v4();
      _draftSignature = signature;
    }
    setState(() => _sending = true);
    try {
      final data = await widget.app.api.request(
        'POST',
        '/conversations/${widget.conversation.id}/messages',
        data: {
          'client_id': _draftID,
          'text': text,
          if (_attachment != null) 'attachment_id': _attachment!.id,
          if (_reply != null) 'reply_to_id': _reply!.id,
        },
      );
      if (!mounted) return;
      setState(() {
        _upsert(Message.fromJson(data));
        _text.clear();
        _reply = null;
        _attachment = null;
        _attachmentBytes = null;
        _draftSignature = null;
        _draftID = null;
      });
      widget.app.realtime.typing(widget.conversation.id, false);
      _toBottom();
      _markRead();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attach() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Bagikan sesuatu',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              const Text('Foto, momen, atau dokumen. Maksimal 8 MB.'),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (final item in [
                    (Icons.photo_outlined, 'Galeri', 'gallery', Colors.purple),
                    if (!kIsWeb)
                      (
                        Icons.camera_alt_outlined,
                        'Kamera',
                        'camera',
                        Colors.pink,
                      ),
                    (
                      Icons.description_outlined,
                      'Dokumen',
                      'document',
                      Colors.blue,
                    ),
                  ])
                    Column(
                      children: [
                        IconButton.filledTonal(
                          onPressed: () => Navigator.pop(context, item.$3),
                          icon: Icon(item.$1, color: item.$4),
                          padding: const EdgeInsets.all(18),
                          iconSize: 28,
                        ),
                        const SizedBox(height: 8),
                        Text(item.$2),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      Uint8List? bytes;
      String? name;
      if (choice == 'document') {
        final result = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: [
            'pdf',
            'txt',
            'jpg',
            'jpeg',
            'png',
            'gif',
            'webp',
          ],
        );
        if (result == null) return;
        final size = await result.length();
        if (size != null && size > 8 * 1024 * 1024) {
          throw Exception('Ukuran lampiran maksimal 8 MB.');
        }
        bytes = await result.readAsBytes();
        name = result.name;
      } else {
        final image = await ImagePicker().pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 2048,
          imageQuality: 85,
        );
        if (image == null) return;
        bytes = await image.readAsBytes();
        name = image.name;
      }
      if (!mounted) return;
      setState(() => _uploading = true);
      final attachment = await widget.app.api.upload(
        widget.conversation.id,
        name,
        bytes,
      );
      if (mounted) {
        setState(() {
          _attachment = attachment;
          _attachmentBytes = bytes;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _react(Message m) async {
    final mine = m.reactions
        .where((r) => r['user_id'] == widget.app.user?.id)
        .firstOrNull;
    final emoji = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  for (final e in ['👍', '❤️', '😂', '😮', '😢', '🙏'])
                    IconButton(
                      tooltip: e,
                      onPressed: () =>
                          Navigator.pop(context, mine?['emoji'] == e ? '' : e),
                      icon: Text(e, style: const TextStyle(fontSize: 27)),
                    ),
                ],
              ),
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Balas pesan'),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
              if (mine != null)
                TextButton(
                  onPressed: () => Navigator.pop(context, ''),
                  child: const Text('Hapus reaksiku'),
                ),
            ],
          ),
        ),
      ),
    );
    if (emoji == null || !mounted) return;
    if (emoji == 'reply') {
      _setReply(m);
      return;
    }
    try {
      await widget.app.api.request(
        'PUT',
        '/messages/${m.id}/reaction',
        data: {'emoji': emoji},
      );
      if (mounted) {
        setState(() {
          m.reactions.removeWhere((r) => r['user_id'] == widget.app.user?.id);
          if (emoji.isNotEmpty) {
            m.reactions.add({'user_id': widget.app.user!.id, 'emoji': emoji});
          }
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.app.realtime.typing(widget.conversation.id, false);
    _subscription?.cancel();
    _typingTimer?.cancel();
    _outgoingTyping?.cancel();
    _text.removeListener(_onText);
    _text.dispose();
    _search.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final visible = _messages
        .where(
          (m) => m.preview.toLowerCase().contains(_search.text.toLowerCase()),
        )
        .toList()
        .reversed
        .toList();
    return Scaffold(
      backgroundColor: dark ? const Color(0xFF111C30) : const Color(0xFFF1F5F9),
      appBar: AppBar(
        titleSpacing: 0,
        title: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ProfileScreen(app: widget.app, peer: _peer),
              ),
            );
            if (mounted) _markRead();
          },
          child: Row(
            children: [
              Hero(
                tag: 'avatar-${_peer.id}',
                child: UserAvatar(user: _peer, radius: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _peer.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _typing
                          ? 'sedang mengetik...'
                          : _peer.online
                          ? 'Online sekarang'
                          : 'Offline',
                      style: TextStyle(
                        fontSize: 11,
                        color: _typing || _peer.online
                            ? const Color(0xFF10B981)
                            : color.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Cari pesan',
            icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            children: [
              ValueListenableBuilder(
                valueListenable: widget.app.realtime.connected,
                builder: (context, online, _) => online
                    ? const SizedBox.shrink()
                    : Material(
                        color: color.tertiaryContainer,
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.sync_rounded, size: 18),
                          title: const Text('Menghubungkan ulang...'),
                          trailing: TextButton(
                            onPressed: widget.app.realtime.reconnect,
                            child: const Text('Coba lagi'),
                          ),
                        ),
                      ),
              ),
              if (_searching)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _search,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Cari pesan',
                      prefixIcon: Icon(Icons.search_rounded),
                    ),
                  ),
                ),
              if (_error != null && _messages.isNotEmpty)
                MaterialBanner(
                  content: Text(_error!),
                  actions: [
                    TextButton(
                      onPressed: _load,
                      child: const Text('Coba lagi'),
                    ),
                  ],
                ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null && _messages.isEmpty
                    ? EmptyState(
                        icon: Icons.wifi_off,
                        title: 'Pesan belum termuat',
                        subtitle: _error!,
                        action: FilledButton(
                          onPressed: _load,
                          child: const Text('Coba lagi'),
                        ),
                      )
                    : _messages.isEmpty
                    ? EmptyState(
                        icon: Icons.waving_hand_outlined,
                        title: 'Mulai dengan sapaan',
                        subtitle: 'Kirim pesan pertama untuk ${_peer.name}.',
                      )
                    : visible.isEmpty
                    ? const EmptyState(
                        icon: Icons.search_off,
                        title: 'Pesan tidak ditemukan',
                        subtitle:
                            'Coba kata kunci lain atau muat pesan sebelumnya.',
                      )
                    : ListView.builder(
                        reverse: true,
                        controller: _scroll,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemCount: visible.length + 1,
                        itemBuilder: (context, index) {
                          if (index == visible.length) {
                            return Padding(
                              padding: const EdgeInsets.all(18),
                              child: _hasMore
                                  ? Center(
                                      child: TextButton.icon(
                                        onPressed: _loadingOlder
                                            ? null
                                            : _older,
                                        icon: _loadingOlder
                                            ? const SizedBox(
                                                width: 14,
                                                height: 14,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.history_rounded,
                                                size: 17,
                                              ),
                                        label: const Text(
                                          'Muat pesan sebelumnya',
                                        ),
                                      ),
                                    )
                                  : const Center(
                                      child: Text(
                                        'Awal percakapan kalian',
                                        style: TextStyle(
                                          color: Color(0xFF94A3B8),
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                            );
                          }
                          final m = visible[index];
                          final isFirstDay =
                              index == visible.length - 1 ||
                              dayLabel(visible[index + 1].createdAt) !=
                                  dayLabel(m.createdAt);
                          return Column(
                            children: [
                              if (isFirstDay)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 13,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: color.surfaceContainerHighest
                                          .withValues(alpha: .7),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      dayLabel(m.createdAt),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: color.onSurfaceVariant,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              Dismissible(
                                key: ValueKey(m.id),
                                direction: DismissDirection.startToEnd,
                                confirmDismiss: (_) async {
                                  _setReply(m);
                                  return false;
                                },
                                background: const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: EdgeInsets.only(left: 24),
                                    child: Icon(
                                      Icons.reply_rounded,
                                      color: brand,
                                    ),
                                  ),
                                ),
                                child: MessageBubble(
                                  message: m,
                                  isMe: m.senderId == widget.app.user?.id,
                                  currentUserId: widget.app.user?.id ?? '',
                                  api: widget.app.api,
                                  onLongPress: () => _react(m),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
              if (_typing)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: color.surface,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const TypingDots(),
                        const SizedBox(width: 9),
                        Text(
                          '${_peer.name.split(' ').first} mengetik',
                          style: TextStyle(
                            fontSize: 11,
                            color: color.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Container(
                decoration: BoxDecoration(
                  color: color.surface,
                  border: Border(
                    top: BorderSide(
                      color: color.outlineVariant.withValues(alpha: .4),
                    ),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_reply != null)
                        Container(
                          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          padding: const EdgeInsets.only(left: 12),
                          decoration: BoxDecoration(
                            color: color.primary.withValues(alpha: .07),
                            border: Border(
                              left: BorderSide(color: color.primary, width: 3),
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Membalas ${_reply!.senderId == widget.app.user?.id ? 'diri sendiri' : _peer.name}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: color.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      _reply!.preview,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Batalkan balasan',
                                onPressed: _sending
                                    ? null
                                    : () => setState(() => _reply = null),
                                icon: const Icon(Icons.close_rounded, size: 18),
                              ),
                            ],
                          ),
                        ),
                      if (_attachment != null)
                        ListTile(
                          dense: true,
                          leading:
                              _attachment!.isImage && _attachmentBytes != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(
                                    _attachmentBytes!,
                                    width: 42,
                                    height: 42,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : const Icon(Icons.description_outlined),
                          title: Text(
                            _attachment!.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: const Text('Siap dikirim'),
                          trailing: IconButton(
                            tooltip: 'Hapus lampiran',
                            onPressed: _sending
                                ? null
                                : () => setState(() {
                                    _attachment = null;
                                    _attachmentBytes = null;
                                  }),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                      if (_uploading) const LinearProgressIndicator(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 10, 12, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: 'Lampirkan file',
                              onPressed: _sending || _uploading
                                  ? null
                                  : _attach,
                              icon: const Icon(
                                Icons.add_circle_outline_rounded,
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                controller: _text,
                                focusNode: _focus,
                                enabled: !_sending,
                                minLines: 1,
                                maxLines: 5,
                                maxLength: 4000,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: const InputDecoration(
                                  hintText: 'Tulis pesan...',
                                  counterText: '',
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                ),
                                keyboardType: TextInputType.multiline,
                              ),
                            ),
                            const SizedBox(width: 8),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              transitionBuilder: (child, animation) =>
                                  ScaleTransition(
                                    scale: animation,
                                    child: child,
                                  ),
                              child: _sending
                                  ? const Padding(
                                      key: ValueKey('busy'),
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : _text.text.trim().isNotEmpty ||
                                        _attachment != null
                                  ? IconButton.filled(
                                      key: const ValueKey('send'),
                                      tooltip: 'Kirim pesan',
                                      onPressed: _uploading ? null : _send,
                                      icon: const Icon(
                                        Icons.arrow_upward_rounded,
                                      ),
                                    )
                                  : IconButton.filledTonal(
                                      key: const ValueKey('media'),
                                      tooltip: 'Kirim foto atau dokumen',
                                      onPressed: _uploading ? null : _attach,
                                      icon: const Icon(
                                        Icons.photo_camera_outlined,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TypingDots extends StatefulWidget {
  const TypingDots({super.key});
  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat();
  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (i) => Opacity(
          opacity: ((_animation.value + i / 3) % 1) * .7 + .3,
          child: Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    ),
  );
}
