typedef Json = Map<String, dynamic>;

class ChatUser {
  const ChatUser({
    required this.id,
    required this.name,
    this.email = '',
    this.online = false,
  });
  final String id, name, email;
  final bool online;
  factory ChatUser.fromJson(Json j) => ChatUser(
    id: j['id'],
    name: j['name'],
    email: j['email'] ?? '',
    online: j['online'] ?? false,
  );
  String get initials => name
      .trim()
      .split(RegExp(r'\s+'))
      .take(2)
      .map((s) => s[0])
      .join()
      .toUpperCase();
  ChatUser withOnline(bool value) =>
      ChatUser(id: id, name: name, email: email, online: value);
}

class Conversation {
  const Conversation({
    required this.id,
    required this.peer,
    required this.lastMessage,
    required this.unread,
    this.updatedAt,
  });
  final String id, lastMessage;
  final ChatUser peer;
  final int unread;
  final DateTime? updatedAt;
  factory Conversation.fromJson(Json j) => Conversation(
    id: j['id'],
    peer: ChatUser.fromJson(j['peer']),
    lastMessage: j['last_message'] ?? '',
    unread: j['unread_count'] ?? 0,
    updatedAt: DateTime.tryParse(j['updated_at'] ?? '')?.toLocal(),
  );
}

class Attachment {
  const Attachment({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
  });
  final String id, name, mime;
  final int size;
  bool get isImage => mime.startsWith('image/');
  factory Attachment.fromJson(Json j) => Attachment(
    id: j['id'],
    name: j['name'],
    mime: j['mime'],
    size: j['size'],
  );
}

class Message {
  Message({
    required this.id,
    required this.senderId,
    required this.clientId,
    required this.text,
    required this.createdAt,
    required this.isRead,
    this.attachment,
    this.reply,
    required this.reactions,
  });
  final String id, senderId, clientId, text;
  final DateTime createdAt;
  bool isRead;
  final Attachment? attachment;
  final Json? reply;
  final List<Json> reactions;
  factory Message.fromJson(Json j) => Message(
    id: j['id'],
    senderId: j['sender_id'],
    clientId: j['client_id'],
    text: j['text'],
    createdAt: DateTime.parse(j['created_at']).toLocal(),
    isRead: j['is_read'] ?? false,
    attachment: j['attachment'] == null
        ? null
        : Attachment.fromJson(j['attachment']),
    reply: j['reply'],
    reactions: (j['reactions'] as List? ?? [])
        .map((e) => Json.from(e))
        .toList(),
  );
  String get preview => text.isNotEmpty ? text : attachment?.name ?? 'Lampiran';
}

String clockLabel(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String dayLabel(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  if (day == today) return 'Hari ini';
  if (day == DateTime(today.year, today.month, today.day - 1)) return 'Kemarin';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'Mei',
    'Jun',
    'Jul',
    'Agu',
    'Sep',
    'Okt',
    'Nov',
    'Des',
  ];
  return '${t.day} ${months[t.month - 1]} ${t.year}';
}
