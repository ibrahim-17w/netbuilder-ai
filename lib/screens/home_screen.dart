import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/build_record.dart';
import '../services/memory_service.dart';
import '../theme/app_theme.dart';

/// Every network this app has built.
///
/// The list is the app's own memory of its work: what was asked, which target
/// it was built for, and how it ended. It reads newest first, is searchable,
/// and opening a row restores the plan exactly as it was compiled.
class HomeScreen extends StatefulWidget {
  final void Function(BuildRecord) onOpen;
  final VoidCallback? onNewBuild;

  const HomeScreen({super.key, required this.onOpen, this.onNewBuild});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _search = TextEditingController();
  List<BuildRecord> _items = [];
  bool _loading = true;
  String _query = '';

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
    setState(() => _loading = true);
    try {
      final mem = context.read<MemoryService>();
      if (mem.ready) {
        _items = await mem.recentBuilds(limit: 200);
      }
    } catch (_) {
      _items = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  List<BuildRecord> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _items;
    bool matches(BuildRecord item) {
      final haystack = '${item.projectName} ${item.instruction} '
          '${item.target} ${item.status}';
      return haystack.toLowerCase().contains(q);
    }

    return _items.where(matches).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return AppEmptyState(
        icon: Icons.hub_outlined,
        title: 'No networks yet',
        body: 'Describe a network in a sentence and this app plans it, '
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
        HistoryDashboard(items: _items),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.s20,
            AppTheme.s16,
            AppTheme.s20,
            AppTheme.s8,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    labelText: 'Search your networks',
                    hintText: 'project, instruction or target',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.s12),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.s20),
          child: Text(
            '${visible.length} of ${_items.length} network(s)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: AppTheme.s8),
        Expanded(
          child: visible.isEmpty
              ? const AppEmptyState(
                  icon: Icons.search_off,
                  title: 'Nothing matches that',
                  body: 'Try part of the project name, or the words you used '
                      'when you asked for it.',
                )
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                      AppTheme.s20,
                      0,
                      AppTheme.s20,
                      AppTheme.s20,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (context, index) =>
                        _row(context, visible[index]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, BuildRecord record) {
    final theme = Theme.of(context);
    final status = _status(record, theme);
    return Card(
      child: InkWell(
        onTap: () => widget.onOpen(record),
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(AppTheme.s8),
                decoration: BoxDecoration(
                  color: status.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.rSm),
                ),
                child: Icon(status.icon, size: 18, color: status.color),
              ),
              const SizedBox(width: AppTheme.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            record.projectName,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(width: AppTheme.s8),
                        AppStatusPill(
                          label: status.label,
                          ok: status.ok,
                          warn: status.warn,
                        ),
                        const SizedBox(width: AppTheme.s8),
                        _Tag(text: record.target),
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
                        Text(
                          _when(record.createdAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppTheme.s8),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  ({String label, IconData icon, Color color, bool ok, bool warn}) _status(
    BuildRecord record,
    ThemeData theme,
  ) => switch (record.status) {
    'verified' => (
      label: 'verified',
      icon: Icons.verified_outlined,
      color: const Color(0xFF2E7D32),
      ok: true,
      warn: false,
    ),
    'failed' => (
      label: 'failed',
      icon: Icons.error_outline,
      color: theme.colorScheme.error,
      ok: false,
      warn: true,
    ),
    'corrected' => (
      label: 'corrected',
      icon: Icons.build_outlined,
      color: const Color(0xFFEF6C00),
      ok: false,
      warn: false,
    ),
    'planned' => (
      label: 'planned',
      icon: Icons.schedule,
      color: theme.colorScheme.primary,
      ok: false,
      warn: false,
    ),
    _ => (
      label: record.status,
      icon: Icons.pending_actions,
      color: theme.colorScheme.onSurfaceVariant,
      ok: false,
      warn: false,
    ),
  };

  /// "3 hours ago" reads faster than a timestamp when scanning a list, and the
  /// exact time is still there in the tooltip.
  static String _when(DateTime when) {
    final now = DateTime.now();
    final diff = now.difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} minute(s) ago';
    if (diff.inHours < 24) return '${diff.inHours} hour(s) ago';
    if (diff.inDays < 7) return '${diff.inDays} day(s) ago';
    final local = when.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
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
        color: theme.colorScheme.primary,
      ),
      (
        label: 'Verified rate',
        value: '$rate%',
        color: const Color(0xFF2E7D32),
      ),
      (
        label: 'Needs attention',
        value: '$failed',
        color: failed > 0 ? theme.colorScheme.error : theme.colorScheme.outline,
      ),
      (
        label: 'Last 7 days',
        value: '$recent',
        color: theme.colorScheme.tertiary,
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.s20,
        AppTheme.s12,
        AppTheme.s20,
        AppTheme.s4,
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            if (i > 0) const SizedBox(width: AppTheme.s8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: AppTheme.s10,
                  horizontal: AppTheme.s10,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppTheme.rSm),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cells[i].value,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: cells[i].color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      cells[i].label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;

  const _Tag({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.s8,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
