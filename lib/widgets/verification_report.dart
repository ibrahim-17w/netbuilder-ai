import 'package:flutter/material.dart';

import '../theme/app_kit.dart';
import '../theme/app_palette.dart';

/// Post-build verification report: one row per derived test with a
/// pass/fail/skip chip, the target, and the evidence line. Consumes the
/// `/verify/run` report shape:
///   { passed, failed, skipped, total, summary, tests: [{src, dst, kind,
///     detail, status, evidence}] }
class VerificationReport extends StatelessWidget {
  final Map<String, dynamic>? report;
  final VoidCallback? onRerun;
  final bool busy;

  const VerificationReport({
    super.key,
    required this.report,
    this.onRerun,
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
      subtitle: 'Every derived ping test, with the evidence it produced.',
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
            )
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
                        child: Text('Pinging every endpoint in Packet Tracer...')),
                  ],
                ),
              ),
            ]
          : [
              Text(
                (report?['summary'] as String?) ??
                    'No verification has run yet.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
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
      _ => 'SKIP',
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
              _ => AppTone.neutral,
            },
            mono: true,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${t['src'] is String && (t['src'] as String).isNotEmpty ? '${t['src']} -> ' : ''}'
                  '${t['dst'] ?? ''}'
                  '${t['kind'] == 'custom' ? ' (manual)' : ''}',
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
