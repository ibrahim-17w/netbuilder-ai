import 'package:flutter/material.dart';

import '../models/chat_message.dart';

/// The in-conversation search sheet: a field, the hits, nothing else.
///
/// Hits match message text only - tool cards and attachments are not prose
/// to search - and each hit shows the line it was found on, so picking the
/// right one is a reading decision, not a guess between timestamps.
class ConversationSearch extends StatefulWidget {
  final List<ChatMessage> messages;
  final ValueChanged<ChatMessage> onOpen;

  /// Formats a stored timestamp for the hit subtitle. Passed in so this leaf
  /// widget does not depend on the chat screen's formatter.
  final String Function(String createdAt) stamp;

  const ConversationSearch({
    super.key,
    required this.messages,
    required this.onOpen,
    required this.stamp,
  });

  @override
  State<ConversationSearch> createState() => _ConversationSearchState();
}

class _ConversationSearchState extends State<ConversationSearch> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  /// The turns whose text contains the query, oldest first. An empty query
  /// matches nothing: an empty hit list is the honest answer to an empty box.
  static List<ChatMessage> matches(List<ChatMessage> messages, String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    return [
      for (final message in messages)
        if (message.text.toLowerCase().contains(needle)) message,
    ].take(50).toList();
  }

  /// A one-to-two-line window around the first hit, whitespace flattened so
  /// a hit inside a wrapped paragraph reads as one line of context instead
  /// of a mangled block.
  static String snippet(String text, String query) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final needle = query.trim().toLowerCase();
    final at = flat.toLowerCase().indexOf(needle);
    if (at < 0) {
      return flat.length <= 120 ? flat : '${flat.substring(0, 120)}...';
    }
    const window = 60;
    // clamp answers a num; substring wants ints.
    final start = (at - window / 3).floor().clamp(0, flat.length).toInt();
    final end = (at + needle.length + window).clamp(0, flat.length).toInt();
    return '${start > 0 ? '...' : ''}${flat.substring(start, end)}'
        '${end < flat.length ? '...' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hits = matches(widget.messages, _field.text);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _field,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 20),
                    hintText: 'Search this conversation',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const Divider(height: 1),
              if (hits.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _field.text.trim().isEmpty
                        ? 'Type to search the messages in this conversation.'
                        : 'No messages in this conversation match that.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final message in hits)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            message.isUser
                                ? Icons.person_outline
                                : Icons.auto_awesome,
                            size: 18,
                          ),
                          title: Text(
                            snippet(message.text, _field.text),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${message.isUser ? 'You' : 'Assistant'}'
                            '${widget.stamp(message.createdAt).isEmpty ? '' : ' - ${widget.stamp(message.createdAt)}'}',
                            style: theme.textTheme.labelSmall,
                          ),
                          onTap: () => widget.onOpen(message),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
