import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/network_intent.dart';
import '../services/adapters/cisco_adapter.dart';
import '../services/adapters/gns3_adapter.dart';
import '../services/adapters/packet_tracer_adapter.dart';
import '../services/adapters/terraform_adapter.dart';
import '../services/diagnostics_service.dart';
import '../services/network_math.dart';
import '../services/network_tools.dart';
import '../services/validator_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';

/// The sections of the toolkit. Named rather than numbered because the
/// capability registry opens the toolkit *at a section* - "Subnet
/// calculator" has to land on the calculator, not on whatever happens to be
/// first.
enum ToolkitSection {
  subnet,
  vlsm,
  summarize,
  addressing,
  acl,
  diagnostics,
  local,
  exporters;

  String get title => switch (this) {
    ToolkitSection.subnet => 'Subnet calculator',
    ToolkitSection.vlsm => 'VLSM and splitting',
    ToolkitSection.summarize => 'Summarization and ranges',
    ToolkitSection.addressing => 'Address plan checks',
    ToolkitSection.acl => 'ACL and masks',
    ToolkitSection.diagnostics => 'Live diagnostics',
    ToolkitSection.local => 'This machine',
    ToolkitSection.exporters => 'Config and IaC exports',
  };

  String get blurb => switch (this) {
    ToolkitSection.subnet =>
      'Network, mask, wildcard, host range, scope and the binary view.',
    ToolkitSection.vlsm =>
      'Allocate a block by host counts, or carve it into equal subnets.',
    ToolkitSection.summarize =>
      'Aggregate prefixes into summary routes, or turn an address range into CIDRs.',
    ToolkitSection.addressing =>
      'Duplicate addresses, overlapping subnets and reserved-address misuse.',
    ToolkitSection.acl =>
      'Inverse masks, mask-to-prefix, reverse DNS and ready ACL lines.',
    ToolkitSection.diagnostics =>
      'DNS, TCP ports, HTTP and ICMP - run from this machine to your target.',
    ToolkitSection.local =>
      'Interfaces, ARP table, route table and open connections.',
    ToolkitSection.exporters =>
      'Cisco IOS, Packet Tracer CLI, GNS3 project and Terraform from the current plan.',
  };

  IconData get icon => switch (this) {
    ToolkitSection.subnet => Icons.calculate_outlined,
    ToolkitSection.vlsm => Icons.call_split,
    ToolkitSection.summarize => Icons.compress,
    ToolkitSection.addressing => Icons.rule_folder_outlined,
    ToolkitSection.acl => Icons.shield_outlined,
    ToolkitSection.diagnostics => Icons.network_ping,
    ToolkitSection.local => Icons.computer_outlined,
    ToolkitSection.exporters => Icons.ios_share,
  };
}

/// The networking console: the arithmetic and the live checks a network
/// engineer needs, each one a button or a field.
///
/// Everything the app already knew how to do but only used internally lives
/// here with an interface on it - the subnet maths the validator used, the
/// adapters that only ran during a build, the diagnostics the sidecar never
/// exposed. It is deliberately separate from the chat: a calculator is a tool,
/// not a conversation, and making someone ask a language model for a broadcast
/// address would be worse engineering than a field and an answer.
class NetworkToolkitScreen extends StatefulWidget {
  final ToolkitSection initialSection;
  final NetworkIntent? intent;

  const NetworkToolkitScreen({
    super.key,
    this.initialSection = ToolkitSection.subnet,
    this.intent,
  });

  @override
  State<NetworkToolkitScreen> createState() => _NetworkToolkitScreenState();
}

class _NetworkToolkitScreenState extends State<NetworkToolkitScreen> {
  late ToolkitSection _section = widget.initialSection;

  /// The toolkit is opened *at* a section by the hub, so being handed a
  /// different one has to actually move it - a screen that ignores its own
  /// argument would silently show the calculator for "open the ACL helper".
  @override
  void didUpdateWidget(covariant NetworkToolkitScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection) {
      setState(() => _section = widget.initialSection);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Network toolkit'),
        actions: [
          IconButton(
            tooltip: 'Explain this section',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showLinesDialog(
              context,
              title: _section.title,
              subtitle: _section.blurb,
              icon: _section.icon,
              lines: const [
                'Every result here is computed locally: no request leaves '
                    'this machine except the diagnostics you start yourself.',
                'The arithmetic is the same code the plan validator uses, so '
                    'the toolkit and a build can never disagree.',
              ],
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // A rail on a desktop, chips on a phone. Same sections either way.
          final wide = constraints.maxWidth >= 900;
          final body = _sectionBody();
          if (!wide) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppTheme.s12,
                      vertical: AppTheme.s4,
                    ),
                    children: [
                      for (final section in ToolkitSection.values)
                        Padding(
                          padding: const EdgeInsets.only(right: AppTheme.s6),
                          child: ChoiceChip(
                            selected: section == _section,
                            avatar: Icon(section.icon, size: 16),
                            label: Text(section.title),
                            onSelected: (_) =>
                                setState(() => _section = section),
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(child: body),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 268,
                child: NavigationRail(
                  extended: true,
                  minExtendedWidth: 268,
                  selectedIndex: _section.index,
                  onDestinationSelected: (index) =>
                      setState(() => _section = ToolkitSection.values[index]),
                  destinations: [
                    for (final section in ToolkitSection.values)
                      NavigationRailDestination(
                        icon: Icon(section.icon),
                        label: Text(section.title),
                      ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                  child: body,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _sectionBody() {
    final intent = widget.intent;
    return switch (_section) {
      ToolkitSection.subnet => const _SubnetTool(),
      ToolkitSection.vlsm => const _VlsmTool(),
      ToolkitSection.summarize => const _SummarizeTool(),
      ToolkitSection.addressing => _AddressingTool(intent: intent),
      ToolkitSection.acl => const _AclTool(),
      ToolkitSection.diagnostics => const _DiagnosticsTool(),
      ToolkitSection.local => const _LocalTool(),
      ToolkitSection.exporters => _ExporterTool(intent: intent),
    };
  }
}

// --- shared scaffolding ----------------------------------------------------

/// A padded, width-limited column so every section reads the same on a phone
/// and on a 4K monitor.
class _Section extends StatelessWidget {
  final String title;
  final String blurb;
  final List<Widget> children;

  const _Section({
    required this.title,
    required this.blurb,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppTheme.s20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.wideMeasure),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: AppTheme.s4),
              Text(
                blurb,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppTheme.s20),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// A labelled field, so a whole section of inputs lines up.
class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final String helper;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.label,
    required this.controller,
    this.hint = '',
    this.helper = '',
    this.maxLines = 1,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s12),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        onChanged: onChanged,
        style: maxLines > 1
            ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint.isEmpty ? null : hint,
          helperText: helper.isEmpty ? null : helper,
          helperMaxLines: 2,
        ),
      ),
    );
  }
}

/// A result block: title, optional copy button, monospaced body.
class _Result extends StatelessWidget {
  final String title;
  final String body;
  final bool error;

  const _Result({required this.title, required this.body, this.error = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: error ? theme.colorScheme.errorContainer.withValues(alpha: 0.35) : null,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.copy_all_outlined),
                  onPressed: () => copyText(context, body, message: 'Copied $title'),
                ),
              ],
            ),
            if (body.trim().isEmpty)
              Text(
                'Nothing to show.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              SelectionArea(
                child: Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A log of probe results: newest first, each with its own copy button and a
/// single "copy everything" for a bug report.
class _ProbeLog extends StatelessWidget {
  final List<({String title, String body, bool error})> entries;
  final VoidCallback onClear;

  const _ProbeLog({required this.entries, required this.onClear});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s12),
          child: Text(
            'No results yet - run a check above.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }
    final all = entries
        .map((e) => '--- ${e.title} ---\n${e.body}')
        .join('\n\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Results',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: () => copyText(context, all, message: 'Copied every result'),
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Copy all'),
            ),
            TextButton(onPressed: onClear, child: const Text('Clear')),
          ],
        ),
        for (final entry in entries)
          _Result(title: entry.title, body: entry.body, error: entry.error),
      ],
    );
  }
}

// --- subnet calculator -----------------------------------------------------

class _SubnetTool extends StatefulWidget {
  const _SubnetTool();

  @override
  State<_SubnetTool> createState() => _SubnetToolState();
}

class _SubnetToolState extends State<_SubnetTool> {
  final _cidr = TextEditingController(text: '192.168.1.0/24');
  var _facts = NetworkMath.facts('192.168.1.0/24');

  void _compute(String value) {
    setState(() => _facts = NetworkMath.facts(value.trim()));
  }

  /// A caret line that lines up under the network part of the binary view:
  /// the split between network bits and host bits is the thing a student is
  /// being asked to see, and a picture of it beats a sentence about it.
  static String _networkMarker(int prefix) {
    const width = 35; // 4 octets of 8 bits plus 3 dots
    final dots = prefix == 0 ? 0 : (prefix - 1) ~/ 8;
    final networkWidth = (prefix + dots).clamp(0, width - 1);
    return '${'<' * networkWidth}|${'>' * (width - networkWidth - 1)}  ';
  }

  @override
  void dispose() {
    _cidr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _facts['ok'] == true;
    return _Section(
      title: ToolkitSection.subnet.title,
      blurb: ToolkitSection.subnet.blurb,
      children: [
        _Field(
          label: 'Address or network (CIDR)',
          controller: _cidr,
          hint: '10.20.30.40/26',
          helper: 'An address in the block is fine - the network is derived.',
          onChanged: _compute,
        ),
        Wrap(
          spacing: AppTheme.s8,
          runSpacing: AppTheme.s8,
          children: [
            for (final preset in const [
              '10.0.0.0/8',
              '172.16.0.0/12',
              '192.168.1.0/24',
              '10.10.10.0/30',
              '192.168.5.130/26',
              '100.64.1.1/10',
            ])
              ActionChip(
                label: Text(preset),
                onPressed: () {
                  _cidr.text = preset;
                  _compute(preset);
                },
              ),
          ],
        ),
        const SizedBox(height: AppTheme.s16),
        if (!ok)
          _Result(
            title: 'Not a valid IPv4 network',
            body: '"${_cidr.text}" did not parse. Expected something like '
                '192.168.1.0/24.',
            error: true,
          )
        else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    NetworkMath.describe(_cidr.text.trim()),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Divider(height: AppTheme.s20),
                  AppKeyValue(label: 'Network', value: '${_facts['network']}'),
                  AppKeyValue(label: 'Prefix', value: '/${_facts['prefix']}'),
                  AppKeyValue(label: 'Subnet mask', value: '${_facts['mask']}'),
                  AppKeyValue(
                    label: 'Wildcard (ACL)',
                    value: '${_facts['wildcard']}',
                  ),
                  AppKeyValue(
                    label: 'Broadcast',
                    value: '${_facts['broadcast']}',
                  ),
                  AppKeyValue(
                    label: 'Host range',
                    value: '${_facts['firstHost']} - ${_facts['lastHost']}',
                  ),
                  AppKeyValue(
                    label: 'Addresses',
                    value:
                        '${_facts['totalAddresses']} total, '
                        '${_facts['usableHosts']} usable',
                  ),
                  AppKeyValue(label: 'Scope', value: '${_facts['scope']}'),
                  AppKeyValue(
                    label: 'Classful',
                    value: 'class ${_facts['classfulClass']}'
                        '${(_facts['classfulMask'] as String).isEmpty ? '' : ' (default mask ${_facts['classfulMask']})'}',
                  ),
                  AppKeyValue(label: 'Reverse DNS', value: '${_facts['reverseDns']}'),
                  AppKeyValue(
                    label: 'Reverse zone',
                    value: '${_facts['reverseZone']}',
                  ),
                  AppKeyValue(
                    label: 'Previous block',
                    value:
                        '${(_facts['previous'] as String).isEmpty ? 'none' : _facts['previous']}',
                  ),
                  AppKeyValue(
                    label: 'Next block',
                    value:
                        '${(_facts['next'] as String).isEmpty ? 'none' : _facts['next']}',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppTheme.s12),
          _Result(
            title: 'Binary',
            body: 'address  ${_facts['binary']}\n'
                'mask     ${_facts['binaryMask']}\n'
                '         ${_networkMarker(_facts['prefix'] as int)}'
                'network part | host part',
          ),
          const SizedBox(height: AppTheme.s12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Split it',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppTheme.s4),
                  Text(
                    'Equal subnets inside ${_facts['network']}/${_facts['prefix']}. '
                    'Tap one to copy it.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppTheme.s8),
                  Wrap(
                    spacing: AppTheme.s6,
                    runSpacing: AppTheme.s6,
                    children: [
                      for (var prefix = (_facts['prefix'] as int) + 1;
                          prefix <= 32 && prefix <= (_facts['prefix'] as int) + 6;
                          prefix++)
                        ActionChip(
                          label: Text(
                            '/$prefix  x${NetworkMath.splitCount(_cidr.text.trim(), prefix)}',
                          ),
                          onPressed: () {
                            final parts = NetworkMath.split(
                              _cidr.text.trim(),
                              prefix,
                            );
                            if (parts.isEmpty) {
                              showLinesDialog(
                                context,
                                title: 'That split is too large',
                                lines: [
                                  'Splitting ${_cidr.text.trim()} into /$prefix '
                                      'would produce '
                                      '${NetworkMath.splitCount(_cidr.text.trim(), prefix)} '
                                      'subnets, which is more than this tool '
                                      'will list. Split it in stages.',
                                ],
                                icon: Icons.warning_amber_rounded,
                                warn: true,
                              );
                              return;
                            }
                            showArtifactDialog(
                              context,
                              title: '${NetworkMath.splitCount(_cidr.text.trim(), prefix)} subnets '
                                  'of /$prefix',
                              subtitle: 'From ${_cidr.text.trim()}',
                              text: parts.join('\n'),
                            );
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// --- VLSM ------------------------------------------------------------------

class _VlsmTool extends StatefulWidget {
  const _VlsmTool();

  @override
  State<_VlsmTool> createState() => _VlsmToolState();
}

class _VlsmToolState extends State<_VlsmTool> {
  final _base = TextEditingController(text: '192.168.0.0/22');
  final _rows = <({TextEditingController name, TextEditingController hosts})>[
    (
      name: TextEditingController(text: 'Head office'),
      hosts: TextEditingController(text: '200'),
    ),
    (
      name: TextEditingController(text: 'Branch'),
      hosts: TextEditingController(text: '60'),
    ),
    (
      name: TextEditingController(text: 'Point-to-point'),
      hosts: TextEditingController(text: '2'),
    ),
    (
      name: TextEditingController(text: 'Wi-Fi guest'),
      hosts: TextEditingController(text: '100'),
    ),
  ];
  List<VlsmAllocation> _plan = const [];

  @override
  void initState() {
    super.initState();
    _compute();
  }

  @override
  void dispose() {
    _base.dispose();
    for (final row in _rows) {
      row.name.dispose();
      row.hosts.dispose();
    }
    super.dispose();
  }

  void _compute() {
    final requirements = <({String name, int hosts})>[
      for (final row in _rows)
        if (int.tryParse(row.hosts.text.trim()) != null)
          (
            name: row.name.text.trim().isEmpty
                ? 'site ${_rows.indexOf(row) + 1}'
                : row.name.text.trim(),
            hosts: int.parse(row.hosts.text.trim()),
          ),
    ];
    setState(() {
      _plan = NetworkMath.vlsm(_base.text.trim(), requirements);
    });
  }

  @override
  Widget build(BuildContext context) {
    final baseFacts = NetworkMath.facts(_base.text.trim());
    final used = _plan.where((a) => a.network.isNotEmpty).toList();
    final wasted = used.isEmpty
        ? 0
        : (baseFacts['ok'] == true ? baseFacts['totalAddresses'] as int : 0) -
              used.fold<int>(0, (sum, a) => sum + (1 << (32 - a.prefix)));
    return _Section(
      title: ToolkitSection.vlsm.title,
      blurb: ToolkitSection.vlsm.blurb,
      children: [
        _Field(
          label: 'Block to allocate from',
          controller: _base,
          hint: '192.168.0.0/22',
          helper: baseFacts['ok'] == true
              ? '${baseFacts['totalAddresses']} addresses to hand out'
              : 'Not a valid block yet.',
          onChanged: (_) => _compute(),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Requirements',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _rows.add((
                            name: TextEditingController(),
                            hosts: TextEditingController(text: '24'),
                          ));
                        });
                        _compute();
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add site'),
                    ),
                  ],
                ),
                for (var i = 0; i < _rows.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: AppTheme.s8),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _rows[i].name,
                            onChanged: (_) => _compute(),
                            decoration: const InputDecoration(
                              labelText: 'Site',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppTheme.s8),
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _rows[i].hosts,
                            keyboardType: TextInputType.number,
                            onChanged: (_) => _compute(),
                            decoration: const InputDecoration(
                              labelText: 'Hosts',
                              isDense: true,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () {
                            final row = _rows.removeAt(i);
                            row.name.dispose();
                            row.hosts.dispose();
                            _compute();
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppTheme.s12),
        if (_plan.isEmpty)
          const _Result(
            title: 'Nothing to allocate yet',
            body: 'Enter a valid block and at least one host count.',
          )
        else ...[
          _Result(
            title: 'Allocation (largest first)',
            body: [
              for (final row in _plan)
                row.network.isEmpty
                    ? '${row.name.padRight(22)}  ${row.note}'
                    : '${row.name.padRight(22)}  ${row.network.padRight(20)}  '
                          'mask ${row.mask.padRight(16)}  '
                          '${row.firstHost} - ${row.lastHost}  '
                          '(${row.usableHosts} usable of ${1 << (32 - row.prefix)})'
                          '${row.note.isEmpty ? '' : '  <-- ${row.note}'}',
            ].join('\n'),
          ),
          const SizedBox(height: AppTheme.s12),
          _Result(
            title: 'Fits or not',
            body: used.length == _plan.length
                ? 'All ${used.length} sites fit in ${baseFacts['network']}/${baseFacts['prefix']}.\n'
                      'Unallocated space left: ${1 << (32 - (baseFacts['prefix'] as int))} - '
                      '${used.fold<int>(0, (sum, a) => sum + (1 << (32 - a.prefix)))} addresses.'
                : '${_plan.length - used.length} site(s) do not fit. '
                      'Use a bigger block, or split a requirement.',
            error: used.length != _plan.length,
          ),
          if (wasted > 0 && used.length == _plan.length)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.s12),
              child: Text(
                '$wasted address(es) of ${baseFacts['totalAddresses']} stay '
                'unused with this allocation order.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}

// --- summarize / ranges ----------------------------------------------------

class _SummarizeTool extends StatefulWidget {
  const _SummarizeTool();

  @override
  State<_SummarizeTool> createState() => _SummarizeToolState();
}

class _SummarizeToolState extends State<_SummarizeTool> {
  final _list = TextEditingController(
    text: '10.0.0.0/25\n10.0.0.128/25\n10.0.1.0/25',
  );
  final _start = TextEditingController(text: '10.0.0.5');
  final _end = TextEditingController(text: '10.0.0.90');

  @override
  void dispose() {
    _list.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cidrs = [
      for (final line in _list.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final invalid = [
      for (final cidr in cidrs)
        if (NetworkTools.parseCidr(cidr) == null) cidr,
    ];
    final summary = NetworkMath.summarize(cidrs);
    final range = NetworkMath.rangeToCidrs(_start.text.trim(), _end.text.trim());
    return _Section(
      title: ToolkitSection.summarize.title,
      blurb: ToolkitSection.summarize.blurb,
      children: [
        _Field(
          label: 'Prefixes, one per line',
          controller: _list,
          maxLines: 6,
          hint: '10.0.0.0/25',
          helper: 'Adjacent blocks merge into the shortest covering list.',
          onChanged: (_) => setState(() {}),
        ),
        _Result(
          title: summary.isEmpty
              ? 'Summary'
              : 'Summary: ${cidrs.length} prefixes -> ${summary.length}',
          body: summary.join('\n'),
          error: invalid.isNotEmpty,
        ),
        if (invalid.isNotEmpty) ...[
          const SizedBox(height: AppTheme.s12),
          _Result(
            title: 'Not valid',
            body: invalid.join('\n'),
            error: true,
          ),
        ],
        const Divider(height: AppTheme.s32),
        Text(
          'Address range to prefixes',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppTheme.s8),
        Row(
          children: [
            Expanded(
              child: _Field(
                label: 'First address',
                controller: _start,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: AppTheme.s8),
            Expanded(
              child: _Field(
                label: 'Last address',
                controller: _end,
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        _Result(
          title: range.isEmpty
              ? 'CIDRs'
              : '${range.length} prefix(es) cover the range',
          body: range.join('\n'),
          error: range.isEmpty,
        ),
        const SizedBox(height: AppTheme.s12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Do these two overlap?',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  'Compared against every pair above, plus the two range endpoints.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppTheme.s8),
                Text(
                  NetworkMath.overlaps(_start.text.trim(), _end.text.trim())
                      ? '${_start.text.trim()} and ${_end.text.trim()} '
                            'share addresses (${NetworkMath.coveringPrefix(_start.text.trim(), _end.text.trim()) ?? '?'}).'
                      : 'They do not overlap.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// --- address plan checks ---------------------------------------------------

class _AddressingTool extends StatefulWidget {
  final NetworkIntent? intent;

  const _AddressingTool({this.intent});

  @override
  State<_AddressingTool> createState() => _AddressingToolState();
}

class _AddressingToolState extends State<_AddressingTool> {
  final _manual = TextEditingController(
    text: '10.0.0.0/24\n10.0.0.0/25\n192.168.1.0/24',
  );

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intent = widget.intent;
    final interfaces = <Map<String, dynamic>>[
      if (intent != null)
        for (final a in intent.addressing)
          {'node': a.node, 'iface': a.iface, 'ipCidr': a.ipCidr},
    ];
    final duplicates = NetworkTools.duplicateAddresses(interfaces);
    final subnets = [
      for (final a in interfaces)
        if (a['ipCidr'] != null && (a['ipCidr'] as String).contains('/'))
          a['ipCidr'] as String,
    ];
    final overlaps = NetworkMath.overlappingPairs(subnets.toSet().toList());
    final reserved = [
      for (final entry in interfaces)
        if (NetworkMath.isReservedAddress(
          (entry['ipCidr'] ?? '').toString(),
          (entry['ipCidr'] ?? '').toString().split('/').first,
        ))
          '${entry['node']} ${entry['iface']} is on '
              '${(entry['ipCidr'] ?? '').toString().split('/').first}, which is '
              'the network or broadcast address of that subnet',
    ];
    final issues =
        intent == null ? const [] : ValidatorService.validate(intent);
    final manualList = [
      for (final line in _manual.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    final manualOverlaps = NetworkMath.overlappingPairs(manualList);

    return _Section(
      title: ToolkitSection.addressing.title,
      blurb: ToolkitSection.addressing.blurb,
      children: [
        if (intent == null)
          const _Result(
            title: 'No plan is open',
            body: 'Open the make/build screen to plan a network, or use the '
                'manual check below. Every check here also runs on the '
                'current plan automatically.',
          )
        else ...[
          _Result(
            title: 'Plan under check',
            body: '${intent.projectName}: ${intent.nodes.length} devices, '
                '${intent.links.length} links, '
                '${intent.addressing.length} addressed interfaces, '
                'routing ${intent.routing}.',
          ),
          const SizedBox(height: AppTheme.s12),
          _Result(
            title: duplicates.isEmpty
                ? 'Duplicate addresses: none'
                : 'Duplicate addresses: ${duplicates.length}',
            body: duplicates.isEmpty
                ? ''
                : [
                    for (final d in duplicates)
                      '${d['address']} used by '
                          '${(d['usedBy'] as List).join(', ')}',
                  ].join('\n'),
            error: duplicates.isNotEmpty,
          ),
          const SizedBox(height: AppTheme.s12),
          _Result(
            title: overlaps.isEmpty
                ? 'Overlapping subnets: none'
                : 'Overlapping subnets: ${overlaps.length}',
            body: overlaps.isEmpty
                ? ''
                : [for (final pair in overlaps) '${pair.$1}  <->  ${pair.$2}']
                      .join('\n'),
            error: overlaps.isNotEmpty,
          ),
          const SizedBox(height: AppTheme.s12),
          _Result(
            title: reserved.isEmpty
                ? 'Reserved addresses: none misused'
                : 'Reserved addresses: ${reserved.length}',
            body: reserved.join('\n'),
            error: reserved.isNotEmpty,
          ),
          const SizedBox(height: AppTheme.s12),
          _Result(
            title: issues.isEmpty
                ? 'Validator: clean'
                : 'Validator: ${issues.length} finding(s)',
            body: [
              for (final issue in issues)
                '[${issue.severity}] ${issue.message}',
            ].join('\n'),
            error: issues.any((i) => i.severity == 'error'),
          ),
          const Divider(height: AppTheme.s32),
        ],
        Text(
          'Manual check',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppTheme.s8),
        _Field(
          label: 'Subnets, one per line',
          controller: _manual,
          maxLines: 5,
          hint: '10.0.0.0/24',
          helper: 'Finishes with the pairs that share addresses.',
          onChanged: (_) => setState(() {}),
        ),
        _Result(
          title: manualOverlaps.isEmpty
              ? 'No overlaps in this list'
              : '${manualOverlaps.length} overlap(s) found',
          body: manualOverlaps.isEmpty
              ? ''
              : [
                  for (final pair in manualOverlaps)
                    '${pair.$1} and ${pair.$2} share addresses '
                        '(${NetworkMath.coveringPrefix(pair.$1, pair.$2) ?? '?'})',
                ].join('\n'),
          error: manualOverlaps.isNotEmpty,
        ),
      ],
    );
  }
}

// --- ACL and masks ---------------------------------------------------------

class _AclTool extends StatefulWidget {
  const _AclTool();

  @override
  State<_AclTool> createState() => _AclToolState();
}

class _AclToolState extends State<_AclTool> {
  final _input = TextEditingController(text: '192.168.10.0/24');
  final _aclNumber = TextEditingController(text: '100');
  String _action = 'permit';
  String _protocol = 'tcp';
  final _port = TextEditingController(text: '80');

  @override
  void dispose() {
    _input.dispose();
    _aclNumber.dispose();
    _port.dispose();
    super.dispose();
  }

  /// Either a CIDR or a bare mask - the two things people paste.
  Map<String, String> _resolve(String raw) {
    final value = raw.trim();
    if (value.contains('/')) {
      final info = NetworkTools.subnet(value);
      if (info == null) return const {};
      return {
        'network': info.network,
        'wildcard': NetworkMath.wildcardFromPrefix(info.prefix),
        'mask': info.mask,
        'prefix': '/${info.prefix}',
        'binary': NetworkMath.binary(info.network),
      };
    }
    final prefix = NetworkMath.prefixFromMask(value);
    if (prefix == null) return const {};
    return {
      'network': '0.0.0.0',
      'wildcard': NetworkMath.wildcardFromMask(value),
      'mask': value,
      'prefix': '/$prefix',
      'binary': NetworkMath.binaryMask(prefix),
    };
  }

  @override
  Widget build(BuildContext context) {
    final resolved = _resolve(_input.text);
    final port = _port.text.trim();
    final aclLine = resolved.isEmpty
        ? ''
        : 'access-list ${_aclNumber.text.trim().isEmpty ? '100' : _aclNumber.text.trim()} '
              '$_action $_protocol ${resolved['network']} ${resolved['wildcard']} '
              'any${port.isEmpty ? '' : ' eq $port'}';
    final reverseDns = NetworkMath.reverseDnsName(
      _input.text.contains('/') ? _input.text.split('/').first : _input.text,
    );
    return _Section(
      title: ToolkitSection.acl.title,
      blurb: ToolkitSection.acl.blurb,
      children: [
        _Field(
          label: 'Network (CIDR) or subnet mask',
          controller: _input,
          hint: '192.168.10.0/24  or  255.255.255.0',
          helper: 'A wildcard mask is derived either way.',
          onChanged: (_) => setState(() {}),
        ),
        if (resolved.isEmpty)
          _Result(
            title: 'Could not read that',
            body: 'Expected 192.168.10.0/24 or a contiguous mask like '
                '255.255.255.0.',
            error: true,
          )
        else
          _Result(
            title: 'Masks',
            body: 'network     ${resolved['network']}${resolved['prefix']}\n'
                'mask        ${resolved['mask']}\n'
                'wildcard    ${resolved['wildcard']}\n'
                'binary      ${resolved['binary']}\n'
                'reverse     $reverseDns',
          ),
        const SizedBox(height: AppTheme.s12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Build an ACL line',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppTheme.s8),
                Row(
                  children: [
                    Expanded(
                      child: _Field(
                        label: 'ACL number',
                        controller: _aclNumber,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: AppTheme.s8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _action,
                        decoration: const InputDecoration(
                          labelText: 'Action',
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 'permit', child: Text('permit')),
                          DropdownMenuItem(value: 'deny', child: Text('deny')),
                        ],
                        onChanged: (v) =>
                            setState(() => _action = v ?? 'permit'),
                      ),
                    ),
                    const SizedBox(width: AppTheme.s8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _protocol,
                        decoration: const InputDecoration(
                          labelText: 'Protocol',
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(value: 'ip', child: Text('ip')),
                          DropdownMenuItem(value: 'tcp', child: Text('tcp')),
                          DropdownMenuItem(value: 'udp', child: Text('udp')),
                          DropdownMenuItem(value: 'icmp', child: Text('icmp')),
                        ],
                        onChanged: (v) => setState(() => _protocol = v ?? 'ip'),
                      ),
                    ),
                    const SizedBox(width: AppTheme.s8),
                    Expanded(
                      child: _Field(
                        label: 'Port (optional)',
                        controller: _port,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                if (aclLine.isNotEmpty)
                  _Result(
                    title: 'Standard/extended ACL entry',
                    body: aclLine,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// --- live diagnostics ------------------------------------------------------

class _DiagnosticsTool extends StatefulWidget {
  const _DiagnosticsTool();

  @override
  State<_DiagnosticsTool> createState() => _DiagnosticsToolState();
}

class _DiagnosticsToolState extends State<_DiagnosticsTool> {
  final _host = TextEditingController(text: '1.1.1.1');
  final _url = TextEditingController(text: 'https://example.com');
  final _port = TextEditingController(text: '443');
  final _service = const DiagnosticsService();
  final _log = <({String title, String body, bool error})>[];
  bool _busy = false;

  @override
  void dispose() {
    _host.dispose();
    _url.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _run(String title, Future<String> Function() probe) async {
    setState(() => _busy = true);
    String body;
    var error = false;
    try {
      body = await probe();
    } catch (e) {
      body = e.toString();
      error = true;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _log.insert(0, (title: title, body: body, error: error));
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = _host.text.trim();
    return _Section(
      title: ToolkitSection.diagnostics.title,
      blurb: ToolkitSection.diagnostics.blurb,
      children: [
        _Field(
          label: 'Host or address to probe',
          controller: _host,
          hint: '192.168.1.1',
          helper: 'Used by DNS, ports, ICMP and the route path.',
        ),
        Wrap(
          spacing: AppTheme.s8,
          runSpacing: AppTheme.s8,
          children: [
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('DNS lookup: $host', () async {
                      final r = await _service.lookup(host);
                      return r.summary;
                    }),
              icon: const Icon(Icons.dns_outlined, size: 18),
              label: const Text('DNS lookup'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('Reverse DNS: $host', () async {
                      final r = await _service.reverseLookup(host);
                      return r.summary;
                    }),
              icon: const Icon(Icons.abc, size: 18),
              label: const Text('Reverse DNS'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('Ping $host', () async {
                      final r = await _service.ping(host);
                      return '${r.summary}\n\n'
                          'Interpretation: ${r.ok ? 'the address answered ICMP.' : r.transmitted == 0 ? 'no reply was received - the host is down, filtering ICMP, or the name did not resolve.' : 'the host answered but lost packets, which points at the link rather than the device.'}';
                    }),
              icon: const Icon(Icons.network_ping, size: 18),
              label: const Text('Ping (desktop)'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('Path to $host', () async {
                      final r = await _service.traceroute(host);
                      return r.summary;
                    }),
              icon: const Icon(Icons.route_outlined, size: 18),
              label: const Text('Traceroute (desktop)'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('Common ports on $host', () async {
                      final results = await _service.scanCommonPorts(host);
                      final open = results.where((r) => r.open).toList();
                      return 'Open: ${open.isEmpty ? 'none' : open.map((r) => r.label).join(', ')}\n\n'
                          '${results.map((r) => r.summary).join('\n')}';
                    }),
              icon: const Icon(Icons.lan_outlined, size: 18),
              label: const Text('Scan common ports'),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.s16),
        Row(
          children: [
            Expanded(
              child: _Field(
                label: 'Single port',
                controller: _port,
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: AppTheme.s8),
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s12),
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run('TCP $host:${_port.text.trim()}', () async {
                        final r = await _service.checkPort(
                          host,
                          int.tryParse(_port.text.trim()) ?? 0,
                        );
                        return r.summary;
                      }),
                child: const Text('Check port'),
              ),
            ),
          ],
        ),
        _Field(
          label: 'Web address',
          controller: _url,
          hint: 'https://example.com',
          onChanged: (_) => setState(() {}),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.s16),
          child: OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run('HTTP ${_url.text.trim()}', () async {
                    final r = await _service.checkHttp(_url.text.trim());
                    return r.summary;
                  }),
            icon: const Icon(Icons.public, size: 18),
            label: const Text('HTTP check'),
          ),
        ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        _ProbeLog(
          entries: _log,
          onClear: () => setState(_log.clear),
        ),
        const SizedBox(height: AppTheme.s12),
        Text(
          'Every probe runs from this machine to the address you typed. '
          'Nothing is sent to a third party, and nothing is stored.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

// --- this machine ----------------------------------------------------------

class _LocalTool extends StatefulWidget {
  const _LocalTool();

  @override
  State<_LocalTool> createState() => _LocalToolState();
}

class _LocalToolState extends State<_LocalTool> {
  final _service = const DiagnosticsService();
  final _log = <({String title, String body, bool error})>[];
  bool _busy = false;

  Future<void> _run(String title, Future<String> Function() probe) async {
    setState(() => _busy = true);
    String body;
    var error = false;
    try {
      body = await probe();
    } catch (e) {
      body = e.toString();
      error = true;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _log.insert(0, (title: title, body: body, error: error));
    });
  }

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: ToolkitSection.local.title,
      blurb: ToolkitSection.local.blurb,
      children: [
        Wrap(
          spacing: AppTheme.s8,
          runSpacing: AppTheme.s8,
          children: [
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('Interfaces on this machine', () async {
                      final list = await _service.localInterfaces();
                      if (list.isEmpty) return 'No interfaces were readable.';
                      return list.map((i) => i.summary).join('\n\n');
                    }),
              icon: const Icon(Icons.settings_ethernet, size: 18),
              label: const Text('My interfaces'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('ARP table', () async {
                      final entries = await _service.arpTable();
                      if (entries.isEmpty) {
                        return 'Nothing in the ARP table (or it is not '
                            'readable on this platform).';
                      }
                      return entries
                          .map(
                            (e) => '${e.address.padRight(16)} '
                                '${e.mac.padRight(20)} ${e.dynamic_ ? 'dynamic' : 'static'}'
                                '${e.iface.isEmpty ? '' : '  ${e.iface}'}',
                          )
                          .join('\n');
                    }),
              icon: const Icon(Icons.table_rows_outlined, size: 18),
              label: const Text('ARP table'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('Route table', () async {
                      final r = await _service.routeTable();
                      return r.summary;
                    }),
              icon: const Icon(Icons.alt_route, size: 18),
              label: const Text('Route table'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run('Open connections', () async {
                      final r = await _service.activeConnections();
                      return r.summary;
                    }),
              icon: const Icon(Icons.cable_outlined, size: 18),
              label: const Text('Open connections'),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.s16),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        _ProbeLog(entries: _log, onClear: () => setState(_log.clear)),
      ],
    );
  }
}

// --- exporters -------------------------------------------------------------

class _ExporterTool extends StatelessWidget {
  final NetworkIntent? intent;

  const _ExporterTool({this.intent});

  @override
  Widget build(BuildContext context) {
    final plan = intent;
    return _Section(
      title: ToolkitSection.exporters.title,
      blurb: ToolkitSection.exporters.blurb,
      children: [
        if (plan == null)
          const _Result(
            title: 'No plan is open',
            body: 'Plan a network first - the exporters render the plan that '
                'is currently open, so what you copy is what was reviewed.',
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Current plan: ${plan.projectName}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    '${plan.nodes.length} devices, ${plan.links.length} links, '
                    '${plan.addressing.length} interfaces, routing ${plan.routing}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        if (plan != null) ...[
          const SizedBox(height: AppTheme.s12),
          _ExportTile(
            title: 'Cisco IOS configuration',
            description: 'Hostname, interfaces, routing, security and lines '
                'for every device.',
            icon: Icons.terminal,
            render: () {
              final rendered = CiscoAdapter.render(plan);
              return rendered.entries
                  .map((e) => '! ===== ${e.key} =====\n${e.value}')
                  .join('\n\n');
            },
          ),
          _ExportTile(
            title: 'Packet Tracer CLI',
            description: 'The same plan shaped for Packet Tracer devices.',
            icon: Icons.router_outlined,
            render: () {
              final rendered = PacketTracerAdapter.deviceConfigs(plan);
              return rendered.entries
                  .map((e) => '! ===== ${e.key} =====\n${e.value}')
                  .join('\n\n');
            },
          ),
          _ExportTile(
            title: 'GNS3 project JSON',
            description: 'Nodes, templates and links, ready to import.',
            icon: Icons.hub_outlined,
            render: () => Gns3Adapter.exportJson(plan),
          ),
          _ExportTile(
            title: 'Terraform (AWS VPC)',
            description: 'The cloud equivalent of the same topology.',
            icon: Icons.cloud_outlined,
            render: () => TerraformAdapter.renderAwsVpc(plan),
          ),
          _ExportTile(
            title: 'Plan JSON',
            description: 'The whole intent, for a ticket, an archive or a diff.',
            icon: Icons.data_object,
            // includeSecrets is off: this text is meant to be pasted into a
            // ticket, and a ticket is not a place for credentials.
            render: () => const JsonEncoder.withIndent(
              '  ',
            ).convert(plan.toJson(includeSecrets: false)),
          ),
        ],
      ],
    );
  }
}

class _ExportTile extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;
  final String Function() render;

  const _ExportTile({
    required this.title,
    required this.description,
    required this.icon,
    required this.render,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(description),
        trailing: FilledButton(
            onPressed: () {
            String text;
            try {
              text = render();
            } catch (e) {
              text = 'Could not render this export: $e';
            }
            showArtifactDialog(
              context,
              title: title,
              subtitle: description,
              text: text,
            );
          },
          child: const Text('Generate'),
        ),
      ),
    );
  }
}
