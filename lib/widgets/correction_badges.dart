import 'package:flutter/material.dart';

import '../services/autopilot_service.dart';
import '../theme/app_kit.dart';
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
    final scheme = Theme.of(context).colorScheme;
    final chips = <Widget>[
      if (stale)
        _badge(
          'STALE',
          AppPalette.warning(scheme),
          'User-taught, but the screen stopped verifying it. '
          'Re-teach it or un-teach it from the corrections list.',
        ),
      if (rejected)
        _badge(
          'REJECTED',
          AppPalette.danger(scheme),
          'A teach run tried this and the screen disagreed; '
          'nothing was written to memory.',
        ),
      if (pending)
        _badge(
          'PENDING',
          scheme.primary,
          'Awaiting a teach run',
        ),
      if (verified)
        _badge(
          'VERIFIED',
          AppPalette.success(scheme),
          'Promoted to memory',
        ),
      if (thrash && !pending)
        _badge(
          'x$thrashCount',
          scheme.tertiary,
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
  final void Function(CorrectionRow row)? onTeach;

  const CorrectionsCard({
    super.key,
    required this.snapshot,
    this.onRefresh,
    this.onRevert,
    this.onTeach,
  });

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      icon: Icons.psychology_alt_outlined,
      tone: snapshot.hasStale ? AppTone.warning : AppTone.info,
      title: 'Teaching-loop corrections',
      subtitle:
          '${snapshot.proposedCount} proposed · '
          '${snapshot.verifiedCount} verified · '
          '${snapshot.stale.length} stale · '
          '${snapshot.rejected.length} rejected · '
          '${snapshot.hits} verified hits',
      actions: [
        if (onRefresh != null)
          IconButton(
            tooltip: 'Refresh corrections',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: onRefresh,
          ),
      ],
      children: [
        if (snapshot.isEmpty)
          const Text(
            'No corrections yet. Every fix you teach lands here first as '
            'PENDING; a teach run verifies it on screen.',
            style: TextStyle(fontSize: 11),
          ),
        if (snapshot.hasStale)
          const AppBanner(
            dense: true,
            tone: AppTone.warning,
            message:
                'A correction you taught stopped verifying. It is reported, '
                'never silently dropped - re-teach it or un-teach it below.',
          ),
        for (final row in snapshot.stale)
          _rowTile(
            context,
            row,
            leading: Icons.history_toggle_off,
            iconColor: AppPalette.warning(Theme.of(context).colorScheme),
            onRevert: onRevert,
          ),
        for (final row in snapshot.rejected)
          _rowTile(
            context,
            row,
            leading: Icons.block,
            iconColor: AppPalette.danger(Theme.of(context).colorScheme),
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
            iconColor: Theme.of(context).colorScheme.primary,
            onRevert: onRevert,
            onTeach: onTeach,
          ),
      ],
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
  void Function(CorrectionRow row)? onTeach,
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
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: AppPalette.mutedText(Theme.of(context).colorScheme),
                  ),
                ),
              Row(
                children: [
                  CorrectionBadges.fromRow(row),
                  if (onTeach != null && row.status == 'proposed') ...[
                    const SizedBox(width: 6),
                    // The only way a PROPOSED fix becomes taught: run the
                    // verification against the live screen. Same 44x44 target
                    // as un-teach above.
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      child: Tooltip(
                        message:
                            'Teach ${row.summaryLine} - re-runs this step and '
                            'keeps the fix only if it verifies',
                        child: InkWell(
                          onTap: () => onTeach(row),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.play_arrow,
                                size: 12,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                'teach',
                                style: TextStyle(
                                  fontSize: 10,
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (onRevert != null && row.status == 'verified') ...[
                    const SizedBox(width: 6),
                    // A 44x44 target: the label is 10px, so the tap area around
                    // it used to be far smaller than a finger can hit.
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      child: Tooltip(
                        message: 'Un-teach ${row.summaryLine}',
                        child: InkWell(
                          onTap: () => onRevert(row),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.undo,
                                size: 12,
                                color: AppPalette.mutedText(
                                  Theme.of(context).colorScheme,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Text(
                                'un-teach',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: AppPalette.mutedText(
                                    Theme.of(context).colorScheme,
                                  ),
                                ),
                              ),
                            ],
                          ),
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
