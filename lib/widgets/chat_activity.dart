import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../services/session_state.dart';
import '../services/validator_service.dart';
import '../theme/app_theme.dart';

/// How one step of real work ended.
enum ActivityStatus { running, ok, warning, failed }

/// One thing the APP did - not something the model said it did.
///
/// Every entry comes from an operation that really ran (a tool call against
/// the engine, a validator pass, a .pkt read). There is no generated
/// reasoning text here and no raw chain-of-thought: this panel is a receipt.
class ActivityEntry {
  final String label;
  final String detail;
  final ActivityStatus status;

  const ActivityEntry(
    this.label, {
    this.detail = '',
    this.status = ActivityStatus.ok,
  });

  ActivityEntry copyWith({String? detail, ActivityStatus? status}) =>
      ActivityEntry(
        label,
        detail: detail ?? this.detail,
        status: status ?? this.status,
      );
}

/// The collapsible "what is happening" list under a working turn.
///
/// A simple conversational question produces no entries and therefore no
/// panel: the panel appears only when work actually happened, which is what
/// keeps it informative instead of decorative.
class ActivityPanel extends StatelessWidget {
  final List<ActivityEntry> entries;
  final bool expanded;
  final VoidCallback onToggle;
  final bool working;
  final int? problemCount;

  const ActivityPanel({
    super.key,
    required this.entries,
    required this.expanded,
    required this.onToggle,
    this.working = false,
    this.problemCount,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = working
        ? 'Working through the network...'
        : problemCount != null && problemCount! > 0
        ? 'Checked the network - found $problemCount issue(s)'
        : 'Checked the network';

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s10),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(AppTheme.rMd),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.s12,
                  vertical: AppTheme.s8,
                ),
                child: Row(
                  children: [
                    if (working)
                      const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        Icons.check_circle_outline,
                        size: 15,
                        color: scheme.primary,
                      ),
                    const SizedBox(width: AppTheme.s8),
                    Expanded(
                      child: Text(
                        header,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${entries.length} step(s)',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.s12,
                  0,
                  AppTheme.s12,
                  AppTheme.s10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Divider(
                      height: AppTheme.s12,
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                    for (final entry in entries) _row(theme, entry),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, ActivityEntry entry) {
    final scheme = theme.colorScheme;
    final (icon, color) = switch (entry.status) {
      ActivityStatus.running => (Icons.more_horiz, scheme.onSurfaceVariant),
      ActivityStatus.ok => (Icons.check, scheme.primary),
      ActivityStatus.warning => (Icons.priority_high, scheme.tertiary),
      ActivityStatus.failed => (Icons.close, scheme.error),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Icon(icon, size: 13, color: color),
          ),
          const SizedBox(width: AppTheme.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
                if (entry.detail.trim().isNotEmpty)
                  Text(
                    entry.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The optional panel beside the conversation: the network the chat is about,
/// as data.
///
/// It reads the plan the app actually compiled plus the validator's own
/// output, so everything in it is checkable. It never occupies screen space
/// permanently - it is opened when the user wants to look and closed when they
/// want to talk.
class NetworkInspector extends StatelessWidget {
  final String project;
  final NetworkIntent? intent;
  final SessionState state;
  final List<Map<String, dynamic>> changes;
  final VoidCallback onClose;

  const NetworkInspector({
    super.key,
    required this.project,
    required this.state,
    required this.onClose,
    this.intent,
    this.changes = const [],
  });

  static const double width = 320;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Every rebuild re-asks the validator the same question about the same
    // plan, which is what the memo in validateCached is for: the screen
    // repaints while a reply streams, and walking 54 devices per repaint is
    // a dropped frame each time.
    final issues = intent == null
        ? const <ValidationIssue>[]
        : ValidatorService.validateCached(intent!);
    final errors = issues.where((i) => i.severity == 'error').toList();
    final warnings = issues.where((i) => i.severity == 'warning').toList();

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(
          left: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s12,
              AppTheme.s10,
              AppTheme.s4,
              AppTheme.s6,
            ),
            child: Row(
              children: [
                const Icon(Icons.lan_outlined, size: 16),
                const SizedBox(width: AppTheme.s8),
                Expanded(
                  child: Text(
                    'Network inspector',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Hide the inspector',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppTheme.s12),
              children: [
                _field(theme, 'Network', project.isEmpty ? '(not set)' : project),
                if (state.problem.isNotEmpty)
                  _field(theme, 'Working on', state.problem),
                if (state.focus.isNotEmpty)
                  _field(theme, 'In focus', state.focus.join(', ')),
                if (intent != null) ...[
                  _section(theme, 'Devices (${intent!.nodes.length})'),
                  for (final node in intent!.nodes)
                    _line(
                      theme,
                      node.name,
                      '${node.type}'
                      '${(node.model ?? '').isEmpty ? '' : ' · ${node.model}'}',
                    ),
                  if (intent!.addressing.isNotEmpty) ...[
                    _section(theme, 'Interfaces and addresses'),
                    for (final addr in intent!.addressing)
                      _line(theme, '${addr.node} ${addr.iface}', addr.ipCidr),
                  ],
                  if (intent!.vlans.isNotEmpty)
                    _field(
                      theme,
                      'VLANs',
                      intent!.vlans.map((v) => 'VLAN $v').join(', '),
                    ),
                  _field(
                    theme,
                    'Routing',
                    intent!.routing.isEmpty ? 'none' : intent!.routing,
                  ),
                  if (intent!.security.requested) ...[
                    _section(theme, 'Security controls'),
                    for (final control in _controls(intent!))
                      _line(theme, control, ''),
                  ],
                ] else
                  _hint(
                    theme,
                    'No plan yet. Ask for a network, or open a .pkt, and its '
                    'topology, addressing and problems appear here.',
                  ),
                _section(
                  theme,
                  'Detected problems'
                  '${issues.isEmpty ? '' : ' (${errors.length} error(s), '
                      '${warnings.length} warning(s))'}',
                ),
                if (issues.isEmpty)
                  _hint(theme, 'The validator found nothing to flag.')
                else
                  for (final issue in issues.take(20))
                    _line(
                      theme,
                      issue.severity == 'error' ? 'Error' : 'Warning',
                      issue.message,
                    ),
                _section(theme, 'Changes made (${changes.length})'),
                if (changes.isEmpty)
                  _hint(theme, 'Nothing has been changed in this conversation.')
                else
                  for (final change in changes)
                    _line(
                      theme,
                      '${change['device']} ${change['interface']}'.trim(),
                      '${change['field']}: "${change['oldValue']}" -> '
                          '"${change['newValue']}"'
                          '${(change['undoneAt'] ?? '').toString().isEmpty ? '' : ' (undone)'}',
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static List<String> _controls(NetworkIntent intent) {
    final s = intent.security;
    final out = <String>[];
    if (s.portSecurity) out.add('Port security');
    if (s.dhcpSnooping) out.add('DHCP snooping');
    if (s.aaa) out.add('AAA (${s.aaaProtocol})');
    if (s.ssh) out.add('SSH access');
    if (s.telnet) out.add('Telnet access');
    if (s.etherChannel) out.add('EtherChannel (${s.etherChannelProtocol})');
    if (s.hsrp) out.add('HSRP gateway redundancy');
    if (s.spanningTree) out.add('Spanning-tree root pinning');
    if (s.interVlanRouting) out.add('Inter-VLAN routing');
    if (s.enableSecret != null) out.add('Enable secret set');
    if (s.extendedAcl) out.add('Extended ACL');
    if (s.ipsecVpn) out.add('IPsec VPN');
    return out;
  }

  Widget _section(ThemeData theme, String label) => Padding(
    padding: const EdgeInsets.only(
      top: AppTheme.s12,
      bottom: AppTheme.s4,
    ),
    child: Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.6,
      ),
    ),
  );

  Widget _field(ThemeData theme, String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: AppTheme.s6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: theme.textTheme.bodySmall),
      ],
    ),
  );

  Widget _line(ThemeData theme, String left, String right) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            left,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (right.isNotEmpty)
          Flexible(
            child: Text(
              right,
              textAlign: TextAlign.right,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _hint(ThemeData theme, String text) => Text(
    text,
    style: theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    ),
  );
}
