import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/memory_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/topology_canvas.dart';
import '../widgets/pkt_build_history_panel.dart';

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
  final Set<int> _selectedForCompare = {};

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
          return byStatus != 0 ? byStatus : b.createdAt.compareTo(a.createdAt);
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
              label: const Text('Plan in chat'),
            ),
        ],
      );
    }
    if (_items.isEmpty) {
      return AppPage(
        maxWidth: 1000,
        children: [
          PktBuildHistoryPanel(onOpenPlan: widget.onOpen),
          AppEmptyState(
            icon: Icons.hub_outlined,
            title: 'No saved plans yet',
            body:
                'Describe a network in chat to create a design. Its plan and generated .pkt file will be linked here.',
            actions: [
              if (widget.onNewBuild != null)
                FilledButton.icon(
                  onPressed: widget.onNewBuild,
                  icon: const Icon(Icons.forum_outlined),
                  label: const Text('Plan in chat'),
                ),
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
            ],
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
            if (_selectedForCompare.length == 2)
              OutlinedButton.icon(
                onPressed: _compareSelected,
                icon: const Icon(Icons.compare_arrows, size: 17),
                label: const Text('Compare versions'),
              ),
            PopupMenuButton<_HistorySort>(
              tooltip: 'Sort',
              initialValue: _sort,
              onSelected: (value) => setState(() => _sort = value),
              itemBuilder: (context) => [
                for (final option in _HistorySort.values)
                  PopupMenuItem(value: option, child: Text(option.label)),
              ],
              child: _MenuChip(icon: Icons.swap_vert, label: _sort.label),
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
              PktBuildHistoryPanel(onOpenPlan: widget.onOpen),
              const SizedBox(height: AppTheme.s8),
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
              if (record.id != null)
                Checkbox(
                  value: _selectedForCompare.contains(record.id),
                  onChanged: (selected) => setState(() {
                    if (selected == true) {
                      if (_selectedForCompare.length == 2) {
                        _selectedForCompare.remove(_selectedForCompare.first);
                      }
                      _selectedForCompare.add(record.id!);
                    } else {
                      _selectedForCompare.remove(record.id);
                    }
                  }),
                ),
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
                        value: 'checkpoint',
                        child: Text('Save named checkpoint'),
                      ),
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
      case 'checkpoint':
        final name = TextEditingController();
        final checkpointName = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Save plan checkpoint'),
            content: TextField(
              controller: name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Checkpoint name',
                hintText: 'Before adding guest Wi-Fi',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, name.text.trim()),
                child: const Text('Save checkpoint'),
              ),
            ],
          ),
        );
        name.dispose();
        if (checkpointName == null || checkpointName.isEmpty || !mounted) {
          return;
        }
        try {
          await context.read<MemoryService>().logBuild(
            BuildRecord(
              projectName: record.projectName,
              instruction:
                  'Checkpoint: $checkpointName · ${record.instruction}',
              intentJson: record.intentJson,
              target: record.target,
              success: false,
              status: 'checkpoint',
              createdAt: DateTime.now(),
            ),
          );
          if (!mounted) return;
          messenger?.showSnackBar(
            const SnackBar(content: Text('Named checkpoint saved in history.')),
          );
          await _refresh();
        } catch (e) {
          if (!mounted) return;
          messenger?.showSnackBar(
            SnackBar(content: Text('Could not save checkpoint: $e')),
          );
        }
      case 'copy-brief':
        await Clipboard.setData(ClipboardData(text: record.instruction));
        messenger?.showSnackBar(const SnackBar(content: Text('Brief copied')));
      case 'copy-json':
        await Clipboard.setData(ClipboardData(text: record.intentJson));
        messenger?.showSnackBar(
          const SnackBar(content: Text('Plan JSON copied')),
        );
    }
  }

  Future<void> _compareSelected() async {
    if (_selectedForCompare.length != 2) return;
    final records =
        _items
            .where((r) => r.id != null && _selectedForCompare.contains(r.id))
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (records.length != 2) return;
    final changes = <String>[];
    NetworkIntent? beforeIntent;
    NetworkIntent? afterIntent;
    try {
      final before = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(records[0].intentJson) as Map),
      );
      final after = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(records[1].intentJson) as Map),
      );
      beforeIntent = before;
      afterIntent = after;
      final oldNodes = {for (final n in before.nodes) n.name: n};
      final newNodes = {for (final n in after.nodes) n.name: n};
      if (before.projectName != after.projectName) {
        changes.add(
          'Project name: ${before.projectName} → ${after.projectName}',
        );
      }
      final names = {...oldNodes.keys, ...newNodes.keys}.toList()..sort();
      for (final name in names) {
        final oldNode = oldNodes[name];
        final newNode = newNodes[name];
        if (oldNode == null) {
          changes.add('Device added: $name (${newNode!.type})');
        } else if (newNode == null) {
          changes.add('Device removed: $name (${oldNode.type})');
        } else {
          final oldJson = oldNode.toJson(includeSecrets: false);
          final newJson = newNode.toJson(includeSecrets: false);
          final fields = {...oldJson.keys, ...newJson.keys}.toList()..sort();
          for (final field in fields) {
            if (jsonEncode(oldJson[field]) != jsonEncode(newJson[field])) {
              changes.add(
                'Device $name $field: ${jsonEncode(oldJson[field] ?? 'unset')} → ${jsonEncode(newJson[field] ?? 'unset')}',
              );
            }
          }
        }
      }
      String linkKey(NetLink link) {
        final ends = ['${link.a}:${link.aIf}', '${link.b}:${link.bIf}']..sort();
        final clock = link.dce == null ? '' : ', clock ${link.dce}';
        return '${ends[0]} <-> ${ends[1]} (${link.cable ?? 'auto'}$clock)';
      }

      final oldLinks = before.links.map(linkKey).toSet();
      final newLinks = after.links.map(linkKey).toSet();
      for (final link in (newLinks.difference(oldLinks).toList()..sort())) {
        changes.add('Cable added: $link');
      }
      for (final link in (oldLinks.difference(newLinks).toList()..sort())) {
        changes.add('Cable removed: $link');
      }
      if (before.routing != after.routing) {
        changes.add('Routing: ${before.routing} → ${after.routing}');
      }
      final oldVlans = before.vlans.toList()..sort();
      final newVlans = after.vlans.toList()..sort();
      if (jsonEncode(oldVlans) != jsonEncode(newVlans)) {
        changes.add('VLANs: ${oldVlans.join(', ')} → ${newVlans.join(', ')}');
      }
      if (jsonEncode(before.security.toJson(includeSecrets: false)) !=
          jsonEncode(after.security.toJson(includeSecrets: false))) {
        final oldSecurity = before.security.toJson(includeSecrets: false);
        final newSecurity = after.security.toJson(includeSecrets: false);
        final fields = {...oldSecurity.keys, ...newSecurity.keys}.toList()
          ..sort();
        for (final field in fields) {
          if (jsonEncode(oldSecurity[field]) !=
              jsonEncode(newSecurity[field])) {
            changes.add(
              'Security $field: ${jsonEncode(oldSecurity[field] ?? 'unset')} → ${jsonEncode(newSecurity[field] ?? 'unset')}',
            );
          }
        }
      }
      final oldAddresses = {
        for (final a in before.addressing)
          '${a.node}/${a.iface}':
              '${a.ipCidr}${a.ip6Cidr == null ? '' : ' · ${a.ip6Cidr}'}',
      };
      final newAddresses = {
        for (final a in after.addressing)
          '${a.node}/${a.iface}':
              '${a.ipCidr}${a.ip6Cidr == null ? '' : ' · ${a.ip6Cidr}'}',
      };
      final addressKeys = {...oldAddresses.keys, ...newAddresses.keys}.toList()
        ..sort();
      for (final key in addressKeys) {
        if (oldAddresses[key] != newAddresses[key]) {
          changes.add(
            'Address $key: ${oldAddresses[key] ?? 'none'} → ${newAddresses[key] ?? 'none'}',
          );
        }
      }
    } catch (e) {
      changes.add('These plan versions could not be compared: $e');
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Plan version comparison'),
        content: SizedBox(
          width: 780,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${records[0].projectName} · ${_whenFull(records[0].createdAt)}',
                ),
                Text('compared with ${_whenFull(records[1].createdAt)}'),
                const SizedBox(height: AppTheme.s12),
                if (beforeIntent != null && afterIntent != null) ...[
                  const Text(
                    'Topology preview',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppTheme.s8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            const Text('Earlier version'),
                            SizedBox(
                              height: 230,
                              child: TopologyCanvas(
                                key: ValueKey('before-${records[0].id}'),
                                intent: beforeIntent,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppTheme.s8),
                      Expanded(
                        child: Column(
                          children: [
                            const Text('Newer version'),
                            SizedBox(
                              height: 230,
                              child: TopologyCanvas(
                                key: ValueKey('after-${records[1].id}'),
                                intent: afterIntent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTheme.s12),
                ],
                const Text(
                  'Changes in the saved plan',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppTheme.s6),
                if (changes.isEmpty)
                  const Text(
                    'No device, cable, address, routing, VLAN, or security changes found.',
                  ),
                for (final change in changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.s6),
                    child: Text('• $change'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              widget.onOpen(records[0]);
            },
            child: const Text('Open earlier version'),
          ),
        ],
      ),
    );
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
      'checkpoint' => (
        label: 'checkpoint',
        icon: Icons.bookmark_outline,
        tone: AppTone.info,
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
          Text(label, style: theme.textTheme.labelLarge?.copyWith(color: fg)),
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
    final builds = items.where((r) => r.status != 'checkpoint').toList();
    final total = builds.length;
    final verified = builds.where((r) => r.status == 'verified').length;
    final failed = builds.where((r) => r.status == 'failed').length;
    final weekAgo = DateTime.now().subtract(const Duration(days: 7));
    final recent = builds.where((r) => r.createdAt.isAfter(weekAgo)).length;
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
        color: failed > 0 ? theme.colorScheme.error : theme.colorScheme.outline,
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
