import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/models.dart';
import 'common.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.currentUserId,
    required this.api,
    required this.onLongPress,
  });
  final Message message;
  final bool isMe;
  final String currentUserId;
  final ApiClient api;
  final VoidCallback onLongPress;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final foreground = isMe
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final groups = <String, int>{};
    for (final r in message.reactions) {
      groups.update(r['emoji'], (v) => v + 1, ifAbsent: () => 1);
    }
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width < 600
                ? MediaQuery.sizeOf(context).width * .79
                : 480,
          ),
          child: Column(
            crossAxisAlignment: isMe
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onLongPress: onLongPress,
                onSecondaryTap: onLongPress,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(13, 10, 13, 8),
                  decoration: BoxDecoration(
                    color: isMe
                        ? (dark ? const Color(0xFF0369A1) : brand)
                        : dark
                        ? const Color(0xFF1E293B)
                        : Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isMe ? 18 : 3),
                      bottomRight: Radius.circular(isMe ? 3 : 18),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .025),
                        blurRadius: 3,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (message.reply != null)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: foreground.withValues(alpha: .09),
                            border: Border(
                              left: BorderSide(
                                color: isMe ? const Color(0xFF7DD3FC) : brand,
                                width: 3,
                              ),
                            ),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message.reply!['sender_name'],
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: foreground,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                message.reply!['text'],
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: foreground.withValues(alpha: .8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (message.attachment != null)
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: message.text.isEmpty ? 0 : 8,
                          ),
                          child: AttachmentView(
                            key: ValueKey(message.attachment!.id),
                            attachment: message.attachment!,
                            api: api,
                            foreground: foreground,
                          ),
                        ),
                      if (message.text.isNotEmpty)
                        Text(
                          message.text,
                          style: TextStyle(
                            color: foreground,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            clockLabel(message.createdAt),
                            style: TextStyle(
                              color: foreground.withValues(alpha: .65),
                              fontSize: 9,
                            ),
                          ),
                          if (isMe) ...[
                            const SizedBox(width: 4),
                            Icon(
                              Icons.done_all_rounded,
                              size: 14,
                              color: message.isRead
                                  ? const Color(0xFF7DD3FC)
                                  : Colors.white54,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (groups.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: groups.entries
                        .map(
                          (e) => InkWell(
                            onTap: onLongPress,
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color:
                                      message.reactions.any(
                                        (r) =>
                                            r['emoji'] == e.key &&
                                            r['user_id'] == currentUserId,
                                      )
                                      ? brand.withValues(alpha: .5)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Text(
                                '${e.key}${e.value > 1 ? ' ${e.value}' : ''}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AttachmentView extends StatefulWidget {
  const AttachmentView({
    super.key,
    required this.attachment,
    required this.api,
    required this.foreground,
  });
  final Attachment attachment;
  final ApiClient api;
  final Color foreground;
  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  late Future<Uint8List> _bytes;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    if (widget.attachment.isImage) {
      _bytes = widget.api.attachment(widget.attachment.id);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final bytes = await widget.api.attachment(widget.attachment.id);
      await FilePicker.saveFile(
        dialogTitle: 'Simpan lampiran',
        fileName: widget.attachment.name,
        bytes: bytes,
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.attachment.isImage) {
      return InkWell(
        onTap: _saving ? null : _save,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.description_outlined,
                color: widget.foreground,
                size: 30,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.attachment.name,
                      style: TextStyle(
                        color: widget.foreground,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${(widget.attachment.size / 1024).ceil()} KB · Ketuk untuk simpan',
                      style: TextStyle(
                        color: widget.foreground.withValues(alpha: .7),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      Icons.download_rounded,
                      color: widget.foreground,
                      size: 20,
                    ),
            ],
          ),
        ),
      );
    }
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SizedBox(
            width: 220,
            height: 120,
            child: Center(
              child: TextButton.icon(
                onPressed: () => setState(
                  () => _bytes = widget.api.attachment(widget.attachment.id),
                ),
                icon: Icon(Icons.refresh, color: widget.foreground),
                label: Text(
                  'Muat ulang foto',
                  style: TextStyle(color: widget.foreground),
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const SizedBox(
            width: 220,
            height: 150,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: const Color(0xFF0F172A),
                appBar: AppBar(
                  backgroundColor: const Color(0xFF0F172A),
                  foregroundColor: Colors.white,
                  title: Text(widget.attachment.name),
                ),
                body: Center(
                  child: InteractiveViewer(
                    minScale: .5,
                    maxScale: 5,
                    child: Image.memory(
                      snapshot.data!,
                      errorBuilder: (_, _, _) => const Text(
                        'Foto tidak dapat dibaca.',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.memory(
              snapshot.data!,
              width: 240,
              height: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(
                width: 220,
                height: 120,
                child: Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        );
      },
    );
  }
}
