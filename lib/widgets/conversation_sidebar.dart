import 'package:flutter/material.dart';

import '../services/conversation_titles.dart';
import '../theme/app_theme.dart';

/// The conversations, as a real chat app lists them.
///
/// The list is the app's own database (MemoryService), not a UI-only history:
/// every row here is a saved conversation that can be reopened with its
/// transcript, its summary and its structured state intact. That is the whole
/// point - a sidebar that forgets on restart is a decoration.
///
/// Grouping is by time (Today / Yesterday / the last week / the last month /
/// older) because that is how people look for a chat: "the one from this
/// morning", not "row 27".
class ConversationSidebar extends StatefulWidget {
  final List<Map<String, dynamic>> conversations;
  final String activeId;
  final bool busy;
  final String project;

  final VoidCallback onNewChat;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onDelete;
  final void Function(String id, String title) onRename;

  /// Search text. The parent owns the query so it can hit the database with
  /// it (title AND message text), not just filter the rows it already has.
  final ValueChanged<String> onSearch;
  final String query;

  final VoidCallback onSettings;
  final VoidCallback onCollapse;

  const ConversationSidebar({
    super.key,
    required this.conversations,
    required this.activeId,
    required this.onNewChat,
    required this.onOpen,
    required this.onDelete,
    required this.onRename,
    required this.onSearch,
    required this.onSettings,
    required this.onCollapse,
    this.query = '',
    this.busy = false,
    this.project = '',
  });

  static const double width = 268;

  @override
  State<ConversationSidebar> createState() => _ConversationSidebarState();
}

class _ConversationSidebarState extends State<ConversationSidebar> {
  final _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = _group(widget.conversations);
    // The colour lives on the Material, not on the decorated box: a ListTile
    // inside a coloured DecoratedBox paints its ink splash where nobody can
    // see it (and Flutter asserts about exactly that).
    return Material(
      color: scheme.surfaceContainerLowest,
      child: Container(
        width: ConversationSidebar.width,
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.6),
            ),
          ),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s10,
              AppTheme.s10,
              AppTheme.s6,
              AppTheme.s6,
            ),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: widget.busy ? null : widget.onNewChat,
                    icon: const Icon(Icons.add_comment_outlined, size: 18),
                    label: const Text('New chat'),
                    style: FilledButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.s12,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Hide the conversation list',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  onPressed: widget.onCollapse,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s12,
              0,
              AppTheme.s12,
              AppTheme.s8,
            ),
            child: _searching
                ? TextField(
                    controller: _search,
                    autofocus: true,
                    onChanged: widget.onSearch,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search conversations',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      suffixIcon: IconButton(
                        tooltip: 'Close search',
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _search.clear();
                          widget.onSearch('');
                          setState(() => _searching = false);
                        },
                      ),
                      border: const OutlineInputBorder(),
                    ),
                  )
                : OutlinedButton.icon(
                    onPressed: () => setState(() => _searching = true),
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Search'),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size.fromHeight(38),
                    ),
                  ),
          ),
          // The current network chip only names REAL projects: a raw
          // storage id ("chat 15:2653") is not a network anyone knows, and
          // the pane header already says "New conversation".
          if (widget.project.trim().isNotEmpty &&
              widget.project.trim() != 'default' &&
              !ConversationTitles.isRawId(widget.project))
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.s12,
                0,
                AppTheme.s12,
                AppTheme.s8,
              ),
              child: _NetworkChip(project: widget.project),
            ),
          const Divider(height: 1),
          Expanded(
            child: groups.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppTheme.s16),
                      child: Text(
                        widget.query.trim().isEmpty
                            ? 'No conversations yet.\nAsk something to start one.'
                            : 'Nothing matched "${widget.query.trim()}".',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppTheme.s6,
                    ),
                    children: [
                      for (final group in groups) ..._groupTiles(group, theme),
                    ],
                  ),
          ),
          const Divider(height: 1),
          // Settings: the ONE app-level entry point. Theme and the rest live
          // inside the drawer - a second row of app chrome here read as a
          // second settings tab.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s8,
              AppTheme.s4,
              AppTheme.s8,
              AppTheme.s10,
            ),
            child: ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.settings_outlined, size: 18),
              title: const Text('Settings'),
              onTap: widget.onSettings,
            ),
          ),
          ],
        ),
      ),
    );
  }

  List<Widget> _groupTiles(_ConversationGroup group, ThemeData theme) => [
    Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.s12,
        AppTheme.s10,
        AppTheme.s12,
        AppTheme.s4,
      ),
      child: Text(
        group.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.6,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    for (final chat in group.items)
      _ConversationTile(
        chat: chat,
        selected: chat['id'] == widget.activeId,
        // Switching, renaming or deleting mid-answer would let the in-flight
        // turn finish into whichever conversation is current by the time it
        // lands, so every control on a row waits for the answer to stop.
        busy: widget.busy,
        onOpen: () => widget.onOpen(chat['id'].toString()),
        onRename: () => _rename(chat),
        onDelete: () => widget.onDelete(chat['id'].toString()),
      ),
  ];

  Future<void> _rename(Map<String, dynamic> chat) async {
    final controller = TextEditingController(
      text: (chat['title'] ?? '').toString(),
    );
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename conversation'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Title',
            helperText: 'Leave empty to go back to the automatic title',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    widget.onRename(chat['id'].toString(), result);
  }

  /// Yesterday / last week / last month are calendar buckets, not 24-hour
  /// windows: "Yesterday" that still changes at midnight while you are reading
  /// it is worse than a slightly fuzzy one.
  static List<_ConversationGroup> _group(List<Map<String, dynamic>> chats) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final buckets = <String, List<Map<String, dynamic>>>{
      'Today': [],
      'Yesterday': [],
      'Previous 7 days': [],
      'Previous 30 days': [],
      'Older': [],
    };
    for (final chat in chats) {
      final ms = (chat['at'] as num?)?.toInt() ?? 0;
      final at = ms == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ms);
      final day = at == null ? null : DateTime(at.year, at.month, at.day);
      final label = day == null
          ? 'Older'
          : day == today
          ? 'Today'
          : today.difference(day).inDays == 1
          ? 'Yesterday'
          : today.difference(day).inDays <= 7
          ? 'Previous 7 days'
          : today.difference(day).inDays <= 30
          ? 'Previous 30 days'
          : 'Older';
      buckets[label]!.add(chat);
    }
    return [
      for (final entry in buckets.entries)
        if (entry.value.isNotEmpty)
          _ConversationGroup(entry.key, entry.value),
    ];
  }
}

class _ConversationGroup {
  final String label;
  final List<Map<String, dynamic>> items;
  const _ConversationGroup(this.label, this.items);
}

/// One conversation. The title comes from the store (generated or renamed),
/// and rename/delete are on the row because that is where a person looks for
/// them.
class _ConversationTile extends StatelessWidget {
  final Map<String, dynamic> chat;
  final bool selected;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _ConversationTile({
    required this.chat,
    required this.selected,
    required this.busy,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final messages = (chat['messages'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.s6, vertical: 1),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          onTap: busy ? null : onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s8,
              AppTheme.s6,
              AppTheme.s2,
              AppTheme.s6,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 15,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        ConversationTitles.display(
                          (chat['title'] ?? '').toString(),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      Text(
                        '$messages message(s)',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                // The row's own controls appear on hover on desktop and are
                // always present for the active chat, so rename/delete are
                // reachable without a right-click.
                if (selected)
                  PopupMenuButton<String>(
                    tooltip: 'Conversation options',
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    enabled: !busy,
                    onSelected: (value) =>
                        value == 'rename' ? onRename() : onDelete(),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The collapsed sidebar: New chat, search and settings stay one click away
/// while the conversation gets the width.
class CollapsedConversationRail extends StatelessWidget {
  final VoidCallback onExpand;
  final VoidCallback onNewChat;
  final VoidCallback onSettings;

  const CollapsedConversationRail({
    super.key,
    required this.onExpand,
    required this.onNewChat,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 52,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(
          right: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: AppTheme.s8),
          IconButton(
            tooltip: 'Show the conversation list',
            icon: const Icon(Icons.chevron_right, size: 18),
            onPressed: onExpand,
          ),
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.add_comment_outlined, size: 18),
            onPressed: onNewChat,
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined, size: 18),
            onPressed: onSettings,
          ),
          const SizedBox(height: AppTheme.s8),
        ],
      ),
    );
  }
}

/// Which network this conversation is about.
///
/// Shown so the user never has to re-select the same .pkt: the conversation
/// remembers it, and this is where that fact is visible.
class _NetworkChip extends StatelessWidget {
  final String project;
  const _NetworkChip({required this.project});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.s8,
        vertical: AppTheme.s6,
      ),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppTheme.rMd),
      ),
      child: Row(
        children: [
          Icon(Icons.lan_outlined, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppTheme.s6),
          Expanded(
            child: Text(
              // A raw storage id is not a name a person reads.
              ConversationTitles.display(project),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The new-conversation screen: a welcoming line and the openers that show the
/// range of the app in one tap.
///
/// Deliberately sparse. A new chat is a blank page, and a page covered in
/// cards is not blank.
class ChatWelcome extends StatelessWidget {
  final ValueChanged<String> onSuggestion;
  final bool hasProject;
  final String project;

  /// When true this widget is only the HEAD of the opening screen - the
  /// composer sits under it - so it drops its own scroll view and centring.
  /// Nested scrollables with the same axis fight each other, and the outer
  /// one is the one that has to move.
  final bool embedded;

  const ChatWelcome({
    super.key,
    required this.onSuggestion,
    this.hasProject = false,
    this.project = '',
    this.embedded = false,
  });

  static const suggestions = <(IconData, String, String)>[
    (Icons.search, 'Analyze a network', 'Audit a .pkt for real problems'),
    (Icons.wifi_tethering_error, 'Troubleshoot connectivity', 'Why can\'t PC1 reach Server0?'),
    (Icons.folder_open_outlined, 'Open a .pkt project', 'Work on a saved network'),
    (Icons.fact_check_outlined, 'Check a configuration', 'Review the CLI for mistakes'),
    (Icons.add_road_outlined, 'Create a network', 'Describe a lab and build it'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // THE MARK. An opening screen that starts with bare text reads as
          // a placeholder; a small brand anchor with a soft glow gives the
          // eye somewhere to land and says "this is the app talking to you"
          // before a word is read.
          Container(
            width: 128,
            height: 96,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  scheme.primary.withValues(alpha: 0.16),
                  scheme.primary.withValues(alpha: 0.0),
                ],
              ),
            ),
            child: Center(
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppTheme.rLg),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [scheme.primary, scheme.tertiary],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.lan_outlined,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppTheme.s4),
          Text(
            'What are we building today?',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppTheme.s8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              hasProject && project.isNotEmpty
                  ? 'This conversation is about $project. Describe a problem, '
                        'attach a screenshot, or paste a configuration.'
                  : 'Describe a lab, attach a screenshot, or drop in a .pkt '
                        'save - I plan it, audit it and prove it with you. '
                        'Nothing changes until you approve it.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: AppTheme.s20),
          // Prompt chips, not cards. Five bordered tiles on an empty screen
          // read as a menu to browse; five pills read as things to say, and
          // they take a third of the space.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppTheme.s8,
            runSpacing: AppTheme.s8,
            children: [
              for (final (icon, title, subtitle) in suggestions)
                _SuggestionChip(
                  icon: icon,
                  title: title,
                  subtitle: subtitle,
                  onTap: () => onSuggestion(title),
                ),
            ],
          ),
        ],
      ),
    );
    if (embedded) return body;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.s20),
        child: body,
      ),
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SuggestionChip({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // A pill, not a tile. Five bordered cards on an empty screen read as a
    // menu to browse; five pills read as things to say, and they take a third
    // of the space. The one-line explanation moves into the tooltip so the
    // chip stays one line on a 320px phone.
    return Tooltip(
      message: subtitle,
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AppTheme.rXl),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rXl),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.s14,
              vertical: AppTheme.s8,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.rXl),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: scheme.onSurfaceVariant),
                const SizedBox(width: AppTheme.s8),
                // Flexible, so the LONGEST opener ("Troubleshoot
                // connectivity") ellipsises on a 360px phone instead of
                // pushing past the edge of its own chip.
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
