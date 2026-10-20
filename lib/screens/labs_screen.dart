import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/lab_grading_service.dart';
import '../services/memory_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

class _PracticeLab {
  final String id;
  final String title;
  final String level;
  final String brief;
  final String goal;

  const _PracticeLab({
    required this.id,
    required this.title,
    required this.level,
    required this.brief,
    required this.goal,
  });
}

final _practiceLabs = <_PracticeLab>[
  _PracticeLab(
    id: 'office-vlans-dhcp',
    title: 'Office VLANs and DHCP',
    level: 'Beginner',
    brief: 'VLAN 10 and VLAN 20 with DHCP, 1 router and 1 switch',
    goal:
        'Separate two groups into VLANs and give each group addresses automatically.',
  ),
  _PracticeLab(
    id: 'dns-web-services',
    title: 'DNS and web services',
    level: 'Beginner',
    brief: '1 switch, 2 PCs, and one server providing DNS and HTTP',
    goal:
        'Plan a small network where a client can look up names and reach a web service.',
  ),
  _PracticeLab(
    id: 'two-routers-ospf',
    title: 'Two routers with OSPF',
    level: 'Intermediate',
    brief:
        'Connect 2 routers with OSPF; each router connects to a switch and one PC',
    goal: 'Route between two LANs using OSPF across a router-to-router link.',
  ),
  _PracticeLab(
    id: 'secure-device-management',
    title: 'Secure device management',
    level: 'Intermediate',
    brief:
        '1 router and 1 switch; enable SSH management and switch port security',
    goal:
        'Protect device access and reduce the risk of unauthorized access ports.',
  ),
];

class LabsScreen extends StatefulWidget {
  final void Function(String brief, String project) onUseBrief;

  const LabsScreen({super.key, required this.onUseBrief});

  @override
  State<LabsScreen> createState() => _LabsScreenState();
}

class _LabsScreenState extends State<LabsScreen> {
  bool _busy = false;

  Future<void> _grade(_PracticeLab lab) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final builds = await context.read<MemoryService>().recentBuilds(
        limit: 100,
      );
      if (!mounted) return;
      if (builds.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Build or save a plan first, then come back to grade it.',
            ),
          ),
        );
        return;
      }
      final chosen = await showDialog<BuildRecord>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Choose a saved plan'),
          children: [
            for (final build in builds)
              ListTile(
                title: Text(build.projectName),
                subtitle: Text(
                  '${build.instruction}\n${build.createdAt.toLocal()}',
                ),
                isThreeLine: true,
                onTap: () => Navigator.pop(dialogContext, build),
              ),
          ],
        ),
      );
      if (chosen == null || !mounted) return;
      final plan = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(chosen.intentJson) as Map),
      );
      final results = LabGradingService.grade(lab.id, plan);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          final passed = results.where((r) => r.passed).length;
          return AlertDialog(
            title: Text('${lab.title}: $passed/${results.length} goals'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Plan: ${chosen.projectName}. This scores the saved design against the lab goals.',
                    ),
                    const SizedBox(height: AppTheme.s12),
                    for (final row in results)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          row.passed
                              ? Icons.check_circle_outline
                              : Icons.radio_button_unchecked,
                          color: row.passed
                              ? AppPalette.success(
                                  Theme.of(dialogContext).colorScheme,
                                )
                              : null,
                        ),
                        title: Text(row.label),
                        subtitle: row.passed ? null : Text(row.hint),
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
              if (passed < results.length)
                FilledButton(
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    widget.onUseBrief(lab.brief, _projectFor(lab));
                  },
                  child: const Text('Try this lab'),
                ),
            ],
          );
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not grade this plan: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _projectFor(_PracticeLab lab) => lab.title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'-$'), '');

  @override
  Widget build(BuildContext context) {
    return AppPage(
      maxWidth: 1050,
      header: const AppPageHeader(
        eyebrow: 'Practice',
        title: 'Guided network labs',
        description:
            'Start with a focused network challenge, then grade a saved plan against clear goals.',
      ),
      children: [
        AppBanner(
          tone: AppTone.info,
          title: 'Generated configuration checks',
          message:
              'The score checks topology and the configuration NetBuilder would generate. It does not claim the live Packet Tracer network passed; build it and run Verify for live evidence.',
        ),
        const SizedBox(height: AppTheme.s12),
        for (final lab in _practiceLabs)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.s10),
            child: AppPanel(
              icon: Icons.school_outlined,
              title: lab.title,
              subtitle: '${lab.level} · ${lab.goal}',
              children: [
                Text('Challenge: ${lab.brief}'),
                const SizedBox(height: AppTheme.s10),
                Wrap(
                  spacing: AppTheme.s8,
                  runSpacing: AppTheme.s8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () =>
                                widget.onUseBrief(lab.brief, _projectFor(lab)),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start this lab'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _grade(lab),
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.fact_check_outlined),
                      label: const Text('Grade a saved plan'),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
