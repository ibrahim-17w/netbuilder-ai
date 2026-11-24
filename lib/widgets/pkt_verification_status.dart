import 'package:flutter/material.dart';

import '../models/pkt_verification.dart';

/// Independent evidence stages. A generated or decoded file is not proof that
/// Packet Tracer opened it or that any live connectivity test passed.
class PktVerificationStatus extends StatelessWidget {
  final PktVerificationSummary? verification;

  const PktVerificationStatus({super.key, required this.verification});

  @override
  Widget build(BuildContext context) {
    final summary = verification;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _check(context, 'generated', 'Generated', summary?.generatedState),
        _check(
          context,
          'read-back',
          'File read-back checked',
          summary?.readBackState,
        ),
        _check(
          context,
          'native-open',
          'Opened in Packet Tracer',
          summary?.nativeOpenState,
        ),
        _check(
          context,
          'connectivity',
          'Connectivity tested',
          summary?.connectivityState,
        ),
        if (summary != null &&
            (summary.passed +
                    summary.failed +
                    summary.skipped +
                    summary.manual >
                0))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Recorded live probes: ${summary.passed} passed, ${summary.failed} failed, '
              '${summary.skipped} skipped, ${summary.manual} manual. '
              'Skipped or manual checks are not passes.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (summary != null && summary.nativeVersion.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Native evidence: Packet Tracer ${summary.nativeVersion}. '
              'No cross-version compatibility guarantee.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (summary != null && summary.nativeError.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              summary.nativeError,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _check(
    BuildContext context,
    String id,
    String label,
    PktVerificationCheckState? value,
  ) {
    final state = value ?? PktVerificationCheckState.notChecked;
    final theme = Theme.of(context);
    final text = switch (state) {
      PktVerificationCheckState.notChecked => 'NOT CHECKED',
      PktVerificationCheckState.passed => 'PASSED',
      PktVerificationCheckState.failed => 'FAILED',
      PktVerificationCheckState.partial => 'PARTIAL',
      PktVerificationCheckState.stale => 'STALE',
    };
    final color = switch (state) {
      PktVerificationCheckState.passed => theme.colorScheme.primary,
      PktVerificationCheckState.failed => theme.colorScheme.error,
      PktVerificationCheckState.partial ||
      PktVerificationCheckState.stale => theme.colorScheme.tertiary,
      PktVerificationCheckState.notChecked =>
        theme.colorScheme.onSurfaceVariant,
    };
    final status = Text(
      text,
      style: theme.textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
      ),
    );
    return Semantics(
      key: ValueKey('pkt-verification-$id'),
      container: true,
      label: '$label: $text',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final title = Text(label, style: theme.textTheme.bodySmall);
            // Large text gets the same stacked layout as a narrow phone card.
            if (constraints.maxWidth <
                300 * MediaQuery.textScalerOf(context).scale(1)) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [title, status],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: title),
                const SizedBox(width: 12),
                status,
              ],
            );
          },
        ),
      ),
    );
  }
}
