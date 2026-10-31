import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});
  final AppController app;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Conversation> _conversations = [];
  final _search = TextEditingController();
  StreamSubscription<Json>? _subscription;
  Timer? _refresh;
  bool _loading = true, _unreadOnly = false;
  String? _error;
  int _loadGeneration = 0;
  @override
  void initState() {
    super.initState();
    _load();
    _subscription = widget.app.realtime.events.listen((e) {
      if ([
        'ready',
        'message',
        'read',
        'conversation',
        'presence',
      ].contains(e['type'])) {
        _refresh?.cancel();
        _refresh = Timer(const Duration(milliseconds: 150), _load);
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _refresh?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final data = await widget.app.api.request('GET', '/conversations');
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _conversations = (data['conversations'] as List)
              .map((j) => Conversation.fromJson(j))
              .toList();
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _open(Conversation conversation) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(app: widget.app, conversation: conversation),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _newChat() async {
    final conversation = await showModalBottomSheet<Conversation>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => NewChatSheet(app: widget.app),
    );
    if (conversation != null && mounted) _open(conversation);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final filtered = _conversations
        .where(
          (c) =>
              (!_unreadOnly || c.unread > 0) &&
              '${c.peer.name} ${c.lastMessage}'.toLowerCase().contains(
                _search.text.toLowerCase(),
              ),
        )
        .toList();
    final unreadCount = _conversations.where((c) => c.unread > 0).length;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 16, 0),
                  child: Row(
                    children: [
                      const BrandMark(size: 38),
                      const SizedBox(width: 11),
                      const Text(
                        'ruang',
                        style: TextStyle(
                          fontSize: 28,
                          letterSpacing: -1,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Profil & preferensi',
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ProfileScreen(app: widget.app),
                          ),
                        ),
                        icon: Hero(
                          tag: 'avatar-${widget.app.user!.id}',
                          child: UserAvatar(
                            user: widget.app.user!,
                            radius: 20,
                            showOnline: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 30, 24, 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Percakapan',
                              style: TextStyle(
                                fontSize: 30,
                                letterSpacing: -.8,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            SizedBox(height: 5),
                            Text(
                              'Sapa mereka yang berarti.',
                              style: TextStyle(
                                fontSize: 14,
                                color: Color(0xFF64748B),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ValueListenableBuilder(
                        valueListenable: widget.app.realtime.connected,
                        builder: (context, value, _) => Tooltip(
                          message: value
                              ? 'Terhubung real-time'
                              : 'Menghubungkan ulang',
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color:
                                  (value
                                          ? const Color(0xFF10B981)
                                          : Colors.orange)
                                      .withValues(alpha: .1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.circle,
                                  size: 6,
                                  color: value
                                      ? const Color(0xFF10B981)
                                      : Colors.orange,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  value ? 'Online' : 'Menyambung',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: value
                                        ? const Color(0xFF059669)
                                        : Colors.orange,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Cari nama atau percakapan',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Hapus pencarian',
                              onPressed: () => setState(_search.clear),
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 12),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: const Text('Semua'),
                        selected: !_unreadOnly,
                        onSelected: (_) => setState(() => _unreadOnly = false),
                        showCheckmark: false,
                      ),
                      const SizedBox(width: 10),
                      ChoiceChip(
                        label: Text(
                          'Belum dibaca${unreadCount > 0 ? '  $unreadCount' : ''}',
                        ),
                        selected: _unreadOnly,
                        onSelected: (_) => setState(() => _unreadOnly = true),
                        showCheckmark: false,
                      ),
                    ],
                  ),
                ),
                if (_error != null && _conversations.isNotEmpty)
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
                      : _error != null && _conversations.isEmpty
                      ? EmptyState(
                          icon: Icons.wifi_off_rounded,
                          title: 'Belum terhubung',
                          subtitle: _error!,
                          action: FilledButton(
                            onPressed: _load,
                            child: const Text('Coba lagi'),
                          ),
                        )
                      : filtered.isEmpty
                      ? EmptyState(
                          icon: _search.text.isNotEmpty
                              ? Icons.search_off_rounded
                              : Icons.forum_outlined,
                          title: _search.text.isNotEmpty
                              ? 'Tidak ditemukan'
                              : _unreadOnly
                              ? 'Semua sudah terbaca'
                              : 'Sapaan pertama menunggu',
                          subtitle: _search.text.isNotEmpty
                              ? 'Coba kata kunci yang lain.'
                              : 'Mulai percakapan baru dari tombol di bawah.',
                          action: !_unreadOnly && _search.text.isEmpty
                              ? FilledButton(
                                  onPressed: _newChat,
                                  child: const Text('Mulai chat'),
                                )
                              : null,
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(top: 4, bottom: 110),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) => const Padding(
                              padding: EdgeInsets.only(left: 92, right: 24),
                              child: Divider(height: 1),
                            ),
                            itemBuilder: (context, i) {
                              final c = filtered[i];
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 9,
                                ),
                                onTap: () => _open(c),
                                leading: Hero(
                                  tag: 'avatar-${c.peer.id}',
                                  child: UserAvatar(user: c.peer, radius: 27),
                                ),
                                title: Text(
                                  c.peer.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: c.unread > 0
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                  ),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 5),
                                  child: Text(
                                    c.lastMessage.isEmpty
                                        ? 'Lampiran'
                                        : c.lastMessage,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: c.unread > 0
                                          ? color.onSurface
                                          : color.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      c.updatedAt == null
                                          ? ''
                                          : dayLabel(c.updatedAt!) == 'Hari ini'
                                          ? clockLabel(c.updatedAt!)
                                          : dayLabel(c.updatedAt!),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: c.unread > 0
                                            ? color.primary
                                            : color.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    if (c.unread > 0)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color.primary,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          c.unread > 99 ? '99+' : '${c.unread}',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: color.onPrimary,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      )
                                    else
                                      const SizedBox(height: 18),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newChat,
        icon: const Icon(Icons.edit_square),
        label: const Text('Chat baru'),
        backgroundColor: color.primary,
        foregroundColor: color.onPrimary,
      ),
    );
  }
}

class NewChatSheet extends StatefulWidget {
  const NewChatSheet({super.key, required this.app});
  final AppController app;
  @override
  State<NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<NewChatSheet> {
  List<ChatUser> _users = [];
  Timer? _debounce;
  bool _loading = true, _creating = false;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _find('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _find(String query) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.app.api.request(
        'GET',
        '/users',
        query: {'q': query},
      );
      if (mounted && generation == _generation) {
        setState(
          () => _users = (data['users'] as List)
              .map((j) => ChatUser.fromJson(j))
              .toList(),
        );
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = e.toString());
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .8,
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mulai percakapan',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text('Temukan teman yang sudah bergabung di Ruang.'),
          const SizedBox(height: 20),
          TextField(
            autofocus: false,
            decoration: const InputDecoration(
              hintText: 'Cari nama teman',
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onChanged: (v) {
              _debounce?.cancel();
              _debounce = Timer(
                const Duration(milliseconds: 300),
                () => _find(v),
              );
            },
          ),
          const SizedBox(height: 12),
          if (_creating) const LinearProgressIndicator(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? EmptyState(
                    icon: Icons.wifi_off,
                    title: 'Gagal memuat kontak',
                    subtitle: _error!,
                  )
                : _users.isEmpty
                ? const EmptyState(
                    icon: Icons.person_search_outlined,
                    title: 'Belum ada kontak',
                    subtitle: 'Minta teman membuat akun atau coba nama lain.',
                  )
                : ListView.builder(
                    itemCount: _users.length,
                    itemBuilder: (context, i) {
                      final u = _users[i];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 7),
                        leading: UserAvatar(user: u),
                        title: Text(
                          u.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          u.online ? 'Online sekarang' : 'Pengguna Ruang',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        enabled: !_creating,
                        onTap: () async {
                          setState(() => _creating = true);
                          try {
                            final data = await widget.app.api.request(
                              'POST',
                              '/conversations',
                              data: {'user_id': u.id},
                            );
                            if (context.mounted) {
                              Navigator.pop(
                                context,
                                Conversation.fromJson(data),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          } finally {
                            if (mounted) setState(() => _creating = false);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
