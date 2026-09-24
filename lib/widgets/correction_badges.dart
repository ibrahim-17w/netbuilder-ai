import 'package:flutter/material.dart';

import '../services/autopilot_service.dart';
import '../theme/app_palette.dart';

/// Badge chips for the teaching-loop correction states.
///
/// - STALE    (orange): user-taught, but the screen stopped verifying it.
/// - REJECTED (red): a teach run tried it and the screen disagreed.
/// - PENDING  (blue): proposed, still waiting for a teach run to prove it.
/// - VERIFIED (green): a teach run proved it and it was promoted to memory.
/// - `x<n>`     (purple): the same element was corrected repeatedly - a sign
///   the wrong thing is being blamed.
///
/// The data comes from the sidecar's `/corrections`; a sidecar that is
/// offline simply hides them (empty snapshot), never errors.
class CorrectionBadges extends StatelessWidget {
  final bool stale;
  final bool rejected;
  final bool pending;
  final bool thrash;
  final bool verified;
  final int thrashCount;
  final double fontSize;

  const CorrectionBadges({
    super.key,
    this.stale = false,
    this.rejected = false,
    this.pending = false,
    this.thrash = false,
    this.verified = false,
    this.thrashCount = 0,
    this.fontSize = 10,
  });

  /// Compact badges for one correction row of the proposals / corrections
  /// list.  A stale row is stale *because* the engine kept missing it; that
  /// story lives in the badge tooltip, not a separate chip.
  factory CorrectionBadges.fromRow(
    CorrectionRow row, {
    double fontSize = 10,
  }) {
    return CorrectionBadges(
      stale: row.stale && row.status == 'verified',
      rejected: row.status == 'rejected',
      pending: row.status == 'proposed',
      verified: row.status == 'verified' && !row.stale,
      thrash: row.thrash > 0 && row.status != 'proposed',
      thrashCount: row.thrash,
      fontSize: fontSize,
    );
  }

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      if (stale)
        _badge(
          'STALE',
          Colors.orange,
          'User-taught, but the screen stopped verifying it. '
          'Re-teach it or un-teach it from the corrections list.',
        ),
      if (rejected)
        _badge(
          'REJECTED',
          Colors.red,
          'A teach run tried this and the screen disagreed; '
          'nothing was written to memory.',
        ),
      if (pending) _badge('PENDING', Colors.blue, 'Awaiting a teach run'),
      if (verified) _badge('VERIFIED', Colors.green, 'Promoted to memory'),
      if (thrash && !pending)
        _badge(
          'x$thrashCount',
          Colors.purple,
          'Corrected $thrashCount time(s) before - a repeated edit on the '
          'same element is a sign the wrong thing is being blamed.',
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 4, runSpacing: 2, children: chips);
  }

  Widget _badge(String label, Color color, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

/// The "Teaching-loop corrections" card: counts plus the stale / rejected /
/// pending rows, so taught fixes that stopped working are visible instead of
/// silently failing.  [snapshot] comes from
/// [AutopilotService.correctionSnapshot].
class CorrectionsCard extends StatelessWidget {
  final CorrectionSnapshot snapshot;
  final VoidCallback? onRefresh;
  final void Function(CorrectionRow row)? onRevert;

  const CorrectionsCard({
    super.key,
    required this.snapshot,
    this.onRefresh,
    this.onRevert,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: snapshot.hasStale ? AppPalette.warningFill(Theme.of(context).colorScheme) : AppPalette.infoFill(Theme.of(context).colorScheme),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Teaching-loop corrections',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                if (onRefresh != null)
                  IconButton(
                    tooltip: 'Refresh corrections',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: onRefresh,
                  ),
              ],
            ),
            Text(
              '${snapshot.proposedCount} proposed · '
              '${snapshot.verifiedCount} verified · '
              '${snapshot.stale.length} stale · '
              '${snapshot.rejected.length} rejected · '
              '${snapshot.hits} verified hits',
              style: const TextStyle(fontSize: 11, color: Colors.black87),
            ),
            const SizedBox(height: 4),
            if (snapshot.isEmpty)
              const Text(
                'No corrections yet. Every fix you teach lands here first as '
                'PENDING; a teach run verifies it on screen.',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
            if (snapshot.hasStale)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  'A correction you taught stopped verifying. It is reported, '
                  'never silently dropped - re-teach it or un-teach it below.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AppPalette.warning(Theme.of(context).colorScheme),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            for (final row in snapshot.stale)
              _rowTile(
                context,
                row,
                leading: Icons.history_toggle_off,
                iconColor: Colors.orange,
                onRevert: onRevert,
              ),
            for (final row in snapshot.rejected)
              _rowTile(
                context,
                row,
                leading: Icons.block,
                iconColor: Colors.red,
                onRevert: onRevert,
                subtitleExtra: row.rejectReason.isEmpty
                    ? null
                    : 'why: ${row.rejectReason}',
              ),
            for (final row in snapshot.pending)
              _rowTile(
                context,
                row,
                leading: Icons.hourglass_top,
                iconColor: Colors.blue,
                onRevert: onRevert,
              ),
          ],
        ),
      ),
    );
  }
}

/// One corrections-list row with its badge(s) and optional un-teach action.
Widget _rowTile(
  BuildContext context,
  CorrectionRow row, {
  required IconData leading,
  required Color iconColor,
  void Function(CorrectionRow row)? onRevert,
  String? subtitleExtra,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(leading, size: 16, color: iconColor),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(row.summaryLine, style: const TextStyle(fontSize: 12)),
              if (subtitleExtra != null)
                Text(
                  subtitleExtra,
                  style: const TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: Colors.black54,
                  ),
                ),
              Row(
                children: [
                  CorrectionBadges.fromRow(row),
                  if (onRevert != null && row.status == 'verified') ...[
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: () => onRevert(row),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.undo,
                              size: 12,
                              color: AppPalette.mutedText(Theme.of(context).colorScheme),
                            ),
                            const SizedBox(width: 2),
                            Text(
                              'un-teach',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppPalette.mutedText(Theme.of(context).colorScheme),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
