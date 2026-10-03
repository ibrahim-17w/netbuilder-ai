import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/build_record.dart';
import '../services/memory_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// Every network this app has built.
///
/// The list is the app's own memory of its work: what was asked, which target
/// it was built for, and how it ended. It reads newest first, is searchable,
/// and opening a row restores the plan exactly as it was compiled.
///
/// The list grew a filter and a sort because a real build history stops being
/// a list you read and becomes a list you search: "what failed last week",
/// "the branch lab I built in March". Both are guesses about the same data,
/// so they can never disagree with the rows below them.
class HomeScreen extends StatefulWidget {
  final void Function(BuildRecord) onOpen;
  final VoidCallback? onNewBuild;

  const HomeScreen({super.key, required this.onOpen, this.onNewBuild});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// How the list is ordered. Named, so the menu and the header cannot drift.
enum _HistorySort {
  newest('Newest first'),
  oldest('Oldest first'),
  name('By name'),
  status('By status');

  final String label;
  const _HistorySort(this.label);
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  List<BuildRecord> _items = [];
  bool _loading = true;
  /// Why the list could not be read, verbatim. Null means the read worked -
  /// which is the only way to tell "no networks yet" from "I could not look".
  String? _loadError;
  String _query = '';
  String _statusFilter = 'all';
  _HistorySort _sort = _HistorySort.newest;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final mem = context.read<MemoryService>();
      if (!mem.ready) {
        _items = [];
        _loadError =
            'The local memory database is not open, so the saved networks '
            'cannot be listed. Planning, the toolkit and .pkt work do not need '
            'it, so the rest of the app still works.';
      } else {
        _items = await mem.recentBuilds(limit: 200);
        _loadError = null;
      }
    } catch (e) {
      _items = [];
      _loadError = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => _loading = false);
  }

  List<BuildRecord> get _visible {
    final q = _query.trim().toLowerCase();
    bool matches(BuildRecord item) {
      if (_statusFilter != 'all' &&
          item.status.toLowerCase() != _statusFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      final haystack =
          '${item.projectName} ${item.instruction} '
          '${item.target} ${item.status}';
      return haystack.toLowerCase().contains(q);
    }

    final rows = _items.where(matches).toList();
    switch (_sort) {
      case _HistorySort.newest:
        rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case _HistorySort.oldest:
        rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      case _HistorySort.name:
        rows.sort(
          (a, b) => a.projectName.toLowerCase().compareTo(
            b.projectName.toLowerCase(),
          ),
        );
      case _HistorySort.status:
        rows.sort((a, b) {
          final byStatus = a.status.compareTo(b.status);
          return byStatus != 0
              ? byStatus
              : b.createdAt.compareTo(a.createdAt);
        });
    }
    return rows;
  }

  /// Which statuses actually exist in the history, so the filter row offers
  /// real choices instead of a fixed menu of things that may not be there.
  List<String> get _statuses {
    final seen = <String>{};
    for (final item in _items) {
      final status = item.status.trim().toLowerCase();
      if (status.isNotEmpty) seen.add(status);
    }
    final order = ['verified', 'corrected', 'planned', 'failed'];
    final known = order.where(seen.contains).toList();
    final rest = seen.where((s) => !order.contains(s)).toList()..sort();
    return [...known, ...rest];
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    // A failed read is not an empty list. Saying "No networks yet" after an
    // error tells the user their work is gone, which is both untrue and
    // unrecoverable-looking.
    if (_loadError != null) {
      return AppEmptyState(
        icon: Icons.error_outline,
        danger: true,
        title: 'Saved networks could not be read',
        body: '$_loadError',
        actions: [
          FilledButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
          if (widget.onNewBuild != null)
            OutlinedButton.icon(
              onPressed: widget.onNewBuild,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Plan a network'),
            ),
        ],
      );
    }
    if (_items.isEmpty) {
      return AppEmptyState(
        icon: Icons.hub_outlined,
        title: 'No networks yet',
        body:
            'Describe a network in a sentence and this app plans it, '
            'validates it, builds it and remembers the result. It will be '
            'listed here.',
        actions: [
          if (widget.onNewBuild != null)
            FilledButton.icon(
              onPressed: widget.onNewBuild,
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Plan a network'),
            ),
          OutlinedButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      );
    }

    final visible = _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppToolbar(
          search: AppSearchField(
            controller: _search,
            label: 'Search your networks',
            hint: 'project, instruction or target',
            onChanged: (value) => setState(() => _query = value),
          ),
          filters: [
            _StatusFilter(
              value: _statusFilter,
              statuses: _statuses,
              onChanged: (value) => setState(() => _statusFilter = value),
            ),
            PopupMenuButton<_HistorySort>(
              tooltip: 'Sort',
              initialValue: _sort,
              onSelected: (value) => setState(() => _sort = value),
              itemBuilder: (context) => [
                for (final option in _HistorySort.values)
                  PopupMenuItem(value: option, child: Text(option.label)),
              ],
              child: _MenuChip(
                icon: Icons.swap_vert,
                label: _sort.label,
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
          count: '${visible.length} of ${_items.length} network(s)',
        ),
        Expanded(
          child: AppPage(
            maxWidth: 1000,
            padding: EdgeInsets.fromLTRB(
              AppTheme.gutter(context),
              AppTheme.s16,
              AppTheme.gutter(context),
              AppTheme.s24,
            ),
            children: [
              if (_statusFilter == 'all' && _query.trim().isEmpty)
                HistoryDashboard(items: _items),
              const SizedBox(height: AppTheme.s8),
              if (visible.isEmpty)
                const AppEmptyState(
                  icon: Icons.search_off,
                  title: 'Nothing matches that',
                  body:
                      'Try part of the project name, the words you used when '
                      'you asked for it, or clear the filters.',
                )
              else
                RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: visible.length,
                    itemBuilder: (context, index) =>
                        _row(context, visible[index]),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, BuildRecord record) {
    final theme = Theme.of(context);
    final status = _status(record, theme);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s8),
      child: AppPanel(
        dense: true,
        padding: EdgeInsets.zero,
        onTap: () => widget.onOpen(record),
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppIconBubble(icon: status.icon, tone: status.tone, size: 34),
              const SizedBox(width: AppTheme.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A Wrap, not a Row: a name, a status pill and a target tag
                    // do not fit on one line of a 360dp phone at 1.5x text, and
                    // a clipped tag is worse than a second line.
                    Wrap(
                      spacing: AppTheme.s8,
                      runSpacing: AppTheme.s4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: Text(
                            record.projectName,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        AppTag(
                          label: status.label,
                          tone: status.tone,
                          icon: status.icon,
                        ),
                        AppTag(label: record.target, tone: AppTone.neutral),
                      ],
                    ),
                    const SizedBox(height: AppTheme.s6),
                    Text(
                      record.instruction,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if ((record.error ?? '').trim().isNotEmpty) ...[
                      const SizedBox(height: AppTheme.s6),
                      Text(
                        record.error!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppTheme.s8),
                    Row(
                      children: [
                        Icon(
                          Icons.schedule,
                          size: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: AppTheme.s4),
                        // The relative stamp is for scanning; the exact minute
                        // is here, because "that one" needs a real time.
                        Tooltip(
                          message: _whenFull(record.createdAt),
                          child: Text(
                            _when(record.createdAt),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ),
                        if ((record.fix ?? '').trim().isNotEmpty) ...[
                          const SizedBox(width: AppTheme.s10),
                          Icon(
                            Icons.build_circle_outlined,
                            size: 12,
                            color: AppPalette.warning(theme.colorScheme),
                          ),
                          const SizedBox(width: AppTheme.s4),
                          Flexible(
                            child: Text(
                              record.fix!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: AppPalette.warning(theme.colorScheme),
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.s8),
              Column(
                children: [
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Row actions',
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    onSelected: (value) => _rowAction(value, record),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'copy-brief',
                        child: Text('Copy the brief'),
                      ),
                      PopupMenuItem(
                        value: 'copy-json',
                        child: Text('Copy the plan JSON'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _rowAction(String action, BuildRecord record) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    switch (action) {
      case 'copy-brief':
        await Clipboard.setData(ClipboardData(text: record.instruction));
        messenger?.showSnackBar(
          const SnackBar(content: Text('Brief copied')),
        );
      case 'copy-json':
        await Clipboard.setData(ClipboardData(text: record.intentJson));
        messenger?.showSnackBar(
          const SnackBar(content: Text('Plan JSON copied')),
        );
    }
  }

  ({String label, IconData icon, AppTone tone}) _status(
    BuildRecord record,
    ThemeData theme,
  ) {
    return switch (record.status) {
      'verified' => (
        label: 'verified',
        icon: Icons.verified_outlined,
        tone: AppTone.success,
      ),
      'failed' => (
        label: 'failed',
        icon: Icons.error_outline,
        tone: AppTone.danger,
      ),
      'corrected' => (
        label: 'corrected',
        icon: Icons.build_outlined,
        tone: AppTone.warning,
      ),
      'planned' => (
        label: 'planned',
        icon: Icons.schedule,
        tone: AppTone.accent,
      ),
      _ => (
        label: record.status,
        icon: Icons.pending_actions,
        tone: AppTone.neutral,
      ),
    };
  }

  /// "3 hours ago" reads faster than a timestamp when scanning a list, and the
  /// exact time is still there in the tooltip.
  static String _when(DateTime when) {
    final now = DateTime.now();
    final diff = now.difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} minute(s) ago';
    if (diff.inHours < 24) return '${diff.inHours} hour(s) ago';
    if (diff.inDays < 7) return '${diff.inDays} day(s) ago';
    return _whenFull(when).split(' ').first;
  }

  /// The whole truth about when a build happened, to the minute, in local
  /// time. This is what the tooltip promises, so it has to be a real time and
  /// not another relative phrase.
  static String _whenFull(DateTime when) {
    final local = when.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

/// The status filter: a chip that opens the statuses actually present in the
/// history. A fixed menu would offer "verified" to someone who has never
/// verified anything.
class _StatusFilter extends StatelessWidget {
  final String value;
  final List<String> statuses;
  final ValueChanged<String> onChanged;

  const _StatusFilter({
    required this.value,
    required this.statuses,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value != 'all';
    return PopupMenuButton<String>(
      tooltip: 'Filter by status',
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'all', child: Text('All statuses')),
        for (final status in statuses)
          PopupMenuItem(value: status, child: Text('Status: $status')),
      ],
      child: _MenuChip(
        icon: Icons.filter_alt_outlined,
        label: selected ? 'Status: $value' : 'All statuses',
        active: selected,
      ),
    );
  }
}

/// A toolbar control that looks like an outlined button but is really a menu
/// trigger. Written out because a disabled `OutlinedButton` used as a menu
/// child paints greyed-out, which reads as "this control is unavailable" - the
/// opposite of what it means.
class _MenuChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;

  const _MenuChip({
    required this.icon,
    required this.label,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = active ? scheme.primary : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.s12,
        vertical: AppTheme.s8,
      ),
      decoration: BoxDecoration(
        color: active
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(
          color: active
              ? scheme.primary.withValues(alpha: 0.4)
              : AppPalette.hairline(scheme),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: fg),
          const SizedBox(width: AppTheme.s6),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(color: fg),
          ),
          const SizedBox(width: AppTheme.s4),
          Icon(Icons.expand_more, size: 16, color: fg),
        ],
      ),
    );
  }
}

/// Build-history dashboard: a glanceable strip of the user's build record -
/// total builds, verified rate, failures needing attention, and activity in
/// the last 7 days.  Computed from the same records the list shows, so it
/// can never disagree with it.
class HistoryDashboard extends StatelessWidget {
  final List<BuildRecord> items;

  const HistoryDashboard({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = items.length;
    final verified = items.where((r) => r.status == 'verified').length;
    final failed = items.where((r) => r.status == 'failed').length;
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    final recent = items.where((r) => r.createdAt.isAfter(weekAgo)).length;
    final rate = total == 0 ? 0 : (verified * 100 / total).round();

    final cells = [
      (
        label: 'Builds',
        value: '$total',
        icon: Icons.inventory_2_outlined,
        color: theme.colorScheme.primary,
      ),
      (
        label: 'Verified rate',
        value: '$rate%',
        icon: Icons.verified_outlined,
        color: AppPalette.success(theme.colorScheme),
      ),
      (
        label: 'Needs attention',
        value: '$failed',
        icon: Icons.report_gmailerrorred_outlined,
        color: failed > 0
            ? theme.colorScheme.error
            : theme.colorScheme.outline,
      ),
      (
        label: 'Last 7 days',
        value: '$recent',
        icon: Icons.trending_up,
        color: theme.colorScheme.tertiary,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = AppTheme.s8;
        final columns = (constraints.maxWidth / 150).floor().clamp(2, 4);
        final tileWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final cell in cells)
              SizedBox(
                width: tileWidth,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: AppTheme.s12,
                    horizontal: AppTheme.s12,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.panelAlt(theme.colorScheme),
                    borderRadius: BorderRadius.circular(AppTheme.rMd),
                    border: Border.all(
                      color: AppPalette.hairline(theme.colorScheme),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(cell.icon, size: 14, color: cell.color),
                          const SizedBox(width: AppTheme.s6),
                          Expanded(
                            child: Text(
                              cell.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppTheme.s6),
                      Text(
                        cell.value,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: cell.color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
