import 'package:flutter/material.dart';

import '../theme/app_kit.dart';
import '../theme/app_palette.dart';

/// Post-build verification report: one row per derived test with a
/// pass/fail/skip/manual chip, the target, and the evidence line. Consumes the
/// `/verify/run` report shape:
///   { passed, failed, skipped, total, summary, tests: [{src, dst, kind,
///     detail, status, evidence}] }
class VerificationReport extends StatelessWidget {
  final Map<String, dynamic>? report;
  final VoidCallback? onRerun;
  final ValueChanged<Map<String, dynamic>>? onReviewFailure;
  final bool busy;

  const VerificationReport({
    super.key,
    required this.report,
    this.onRerun,
    this.onReviewFailure,
    this.busy = false,
  });

  static List<Map<String, dynamic>> testsOf(Map<String, dynamic>? report) =>
      ((report?['tests'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tests = testsOf(report);
    if (report == null && !busy) {
      return const SizedBox.shrink();
    }
    return AppPanel(
      icon: Icons.network_check,
      title: 'Verification',
      subtitle:
          'Live reachability and DNS results; other service and security checks stay marked manual until tested.',
      actions: (onRerun != null)
          ? [
              TextButton.icon(
                onPressed: busy ? null : onRerun,
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: const Text('Re-run tests'),
              ),
            ]
          : const [],
      children: busy
          ? const [
              Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Checking network reachability and DNS in Packet Tracer...',
                      ),
                    ),
                  ],
                ),
              ),
            ]
          : [
              Text(
                (report?['summary'] as String?) ??
                    'No verification has run yet.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (report?['error'] != null)
                AppBanner(
                  dense: true,
                  tone: AppTone.danger,
                  message: report!['error'].toString(),
                ),
              const SizedBox(height: 8),
              for (final t in tests) _row(context, t),
            ],
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> t) {
    final status = (t['status'] as String? ?? 'skipped').toLowerCase();
    final glyph = switch (status) {
      'passed' => 'PASS',
      'failed' => 'FAIL',
      'manual' => 'MANUAL',
      _ => t['kind'] == 'custom' ? 'MANUAL' : 'SKIP',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTag(
            label: glyph,
            tone: switch (status) {
              'passed' => AppTone.success,
              'failed' => AppTone.danger,
              'manual' => AppTone.warning,
              _ => t['kind'] == 'custom' ? AppTone.warning : AppTone.neutral,
            },
            mono: true,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t['kind'] == 'dns'
                      ? '${t['src'] ?? ''} -> DNS ${t['query'] ?? ''} (expected ${t['expectedIp'] ?? 'an address'})'
                      : '${t['src'] is String && (t['src'] as String).isNotEmpty ? '${t['src']} -> ' : ''}'
                            '${t['dst'] ?? ''}'
                            '${t['kind'] == 'custom' || t['kind'] == 'manual' ? ' (manual check)' : ''}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  (t['evidence'] as String?)?.isNotEmpty == true
                      ? t['evidence'].toString()
                      : (t['detail'] ?? '').toString(),
                  style: const TextStyle(fontSize: 11.5),
                ),
                if (status == 'failed' && onReviewFailure != null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: () => onReviewFailure!(t),
                      icon: const Icon(Icons.auto_fix_high, size: 16),
                      label: const Text('Review a fix in chat'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
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
