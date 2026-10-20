import 'package:flutter/material.dart';

import '../services/pkt_build_job_service.dart';

/// A small, persistent notice for phone builds that outlive their screen.
class PktBuildJobBanner extends StatelessWidget {
  final VoidCallback onSave;

  const PktBuildJobBanner({super.key, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final jobs = PktBuildJobService.instance;
    return ListenableBuilder(
      listenable: jobs,
      builder: (context, _) {
        final status = jobs.status;
        if (status == PktBuildJobStatus.idle) return const SizedBox.shrink();

        final theme = Theme.of(context);
        final running = status == PktBuildJobStatus.running;
        final ready = status == PktBuildJobStatus.ready;
        final failed = status == PktBuildJobStatus.failed;
        final saved = status == PktBuildJobStatus.saved;
        final cancelled = status == PktBuildJobStatus.cancelled;
        final icon = running
            ? Icons.memory_rounded
            : ready
            ? Icons.check_circle_outline_rounded
            : failed
            ? Icons.error_outline_rounded
            : saved
            ? Icons.task_alt_rounded
            : Icons.cancel_outlined;
        final color = failed
            ? theme.colorScheme.error
            : ready || saved
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant;

        return Material(
          color: theme.colorScheme.surfaceContainerLow,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 8),
                child: Row(
                  children: [
                    Icon(icon, color: color, size: 21),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            jobs.project,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge,
                          ),
                          Text(
                            jobs.error.isNotEmpty
                                ? jobs.error
                                : saved && jobs.savedLocation.isNotEmpty
                                ? 'Saved to ${jobs.savedLocation}'
                                : jobs.stage,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: failed
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (running)
                      IconButton(
                        tooltip: jobs.cancelRequested
                            ? 'Cancelling build'
                            : 'Cancel build',
                        visualDensity: VisualDensity.compact,
                        onPressed: jobs.cancelRequested ? null : jobs.cancel,
                        icon: const Icon(Icons.close_rounded),
                      )
                    else if (ready)
                      TextButton.icon(
                        onPressed: onSave,
                        icon: const Icon(Icons.save_alt_rounded, size: 18),
                        label: const Text('Save .pkt'),
                      )
                    else if (failed || cancelled)
                      IconButton(
                        tooltip: 'Retry build',
                        visualDensity: VisualDensity.compact,
                        onPressed: jobs.retry,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    if (!running)
                      IconButton(
                        tooltip: 'Dismiss build notice',
                        visualDensity: VisualDensity.compact,
                        onPressed: jobs.dismiss,
                        icon: const Icon(Icons.close_rounded, size: 19),
                      ),
                  ],
                ),
              ),
              if (running)
                LinearProgressIndicator(
                  value: jobs.progress,
                  minHeight: 2,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
            ],
          ),
        );
      },
    );
  }
}
