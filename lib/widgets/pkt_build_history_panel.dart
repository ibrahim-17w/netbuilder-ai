import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/pkt_build_job_service.dart';
import '../services/pkt/pkt_export_service.dart';
import '../models/build_record.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';

/// Recent generated .pkt files live beside the existing Packet Tracer file
/// tools, so history is easy to find without adding another navigation item.
class PktBuildHistoryPanel extends StatefulWidget {
  final ValueChanged<BuildRecord>? onOpenPlan;

  const PktBuildHistoryPanel({super.key, this.onOpenPlan});

  @override
  State<PktBuildHistoryPanel> createState() => _PktBuildHistoryPanelState();
}

class _PktBuildHistoryPanelState extends State<PktBuildHistoryPanel> {
  bool _showAll = false;
  final Set<String> _saving = {};

  @override
  void initState() {
    super.initState();
    unawaited(PktBuildJobService.instance.loadHistory());
  }

  Future<void> _saveCopy(PktBuildJobEntry entry) async {
    if (entry.filePath.isEmpty) return;
    final file = File(entry.filePath);
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This generated file is no longer on this device.'),
        ),
      );
      return;
    }
    setState(() => _saving.add(entry.id));
    try {
      final result = await PktExportService.saveToChosenFolder(
        file,
        suggestedName: p.basename(entry.filePath),
      );
      if (!mounted) return;
      if (!result.cancelled && result.path.isNotEmpty) {
        PktBuildJobService.instance.markHistoryItemSaved(entry.id, result.path);
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save this file: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving.remove(entry.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final jobs = PktBuildJobService.instance;
    return ListenableBuilder(
      listenable: jobs,
      builder: (context, _) {
        if (!jobs.historyLoaded) {
          return const AppPanel(
            icon: Icons.history,
            title: 'Recent builds',
            children: [LinearProgressIndicator(minHeight: 2)],
          );
        }
        if (jobs.history.isEmpty) return const SizedBox.shrink();
        final shown = _showAll ? jobs.history : jobs.history.take(5).toList();
        return AppPanel(
          icon: Icons.inventory_2_outlined,
          title: 'Generated .pkt files',
          subtitle:
              'Each file stays linked to the plan version that produced it.',
          actions: jobs.history.length > 5
              ? [
                  TextButton(
                    onPressed: () => setState(() => _showAll = !_showAll),
                    child: Text(_showAll ? 'Show fewer' : 'Show all'),
                  ),
                ]
              : const [],
          children: [for (final entry in shown) _row(context, entry)],
        );
      },
    );
  }

  Widget _row(BuildContext context, PktBuildJobEntry entry) {
    final exists =
        entry.filePath.isNotEmpty && File(entry.filePath).existsSync();
    final theme = Theme.of(context);
    final statusTone = switch (entry.status) {
      PktBuildJobStatus.ready || PktBuildJobStatus.saved => AppTone.success,
      PktBuildJobStatus.failed => AppTone.danger,
      PktBuildJobStatus.cancelled => AppTone.warning,
      _ => AppTone.neutral,
    };
    final statusText = switch (entry.status) {
      PktBuildJobStatus.ready => 'Ready',
      PktBuildJobStatus.saved => 'Saved',
      PktBuildJobStatus.failed => 'Failed',
      PktBuildJobStatus.cancelled => 'Cancelled',
      PktBuildJobStatus.running => 'Interrupted',
      PktBuildJobStatus.idle => 'Unknown',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppTag(
                label: statusText.toUpperCase(),
                tone: statusTone,
                mono: true,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.project,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                    Text(
                      entry.error.isNotEmpty
                          ? entry.error
                          : entry.filePath.isNotEmpty
                          ? '${p.basename(entry.filePath)} · ${entry.deviceCount} devices · ${entry.linkCount} cables${entry.planRevision.isEmpty ? '' : ' · plan ${entry.planRevision.substring(0, entry.planRevision.length > 8 ? 8 : entry.planRevision.length)}'}'
                          : entry.stage,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: entry.error.isNotEmpty
                            ? AppPalette.danger(theme.colorScheme)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if ((entry.planJson.isNotEmpty && widget.onOpenPlan != null) ||
              exists)
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 4,
                children: [
                  if (entry.planJson.isNotEmpty && widget.onOpenPlan != null)
                    TextButton.icon(
                      onPressed: () => widget.onOpenPlan!(
                        BuildRecord(
                          id: entry.sourceRecordId,
                          projectName: entry.project,
                          instruction:
                              'Open linked plan from generated .pkt history',
                          intentJson: entry.planJson,
                          target: entry.target,
                          success: false,
                          status: 'planned',
                          createdAt: entry.updatedAt,
                        ),
                      ),
                      icon: const Icon(Icons.account_tree_outlined, size: 17),
                      label: const Text('Open plan'),
                    ),
                  if (exists)
                    TextButton.icon(
                      onPressed: _saving.contains(entry.id)
                          ? null
                          : () => _saveCopy(entry),
                      icon: _saving.contains(entry.id)
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_alt, size: 17),
                      label: const Text('Save copy'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
