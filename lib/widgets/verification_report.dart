import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
    return AppSection(
      title: 'Verification',
      trailing: (onRerun != null)
          ? TextButton.icon(
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
          : null,
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
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    report!['error'].toString(),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 8),
              ...tests.map(_row),
            ],
    );
  }

  Widget _row(Map<String, dynamic> t) {
    final status = (t['status'] as String? ?? 'skipped').toLowerCase();
    final color = switch (status) {
      'passed' => const Color(0xFF2E7D32),
      'failed' => const Color(0xFFC62828),
      _ => const Color(0xFF9E9E9E),
    };
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
          Container(
            width: 44,
            padding: const EdgeInsets.symmetric(vertical: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              glyph,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
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
