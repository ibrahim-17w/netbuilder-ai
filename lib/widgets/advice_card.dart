import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A design-advice answer as a real card, not just a markdown wall.
///
/// The advisor's answers read well as markdown - recommendation first, then
/// the options table - but the one action a user wants after "2-3 APs,
/// wired, on one generation" had nowhere to live. This card is that place,
/// and it is deliberately COMPACT: the markdown above the card already
/// carries the options, reasons and provenance, so the card carries only
/// the two things markdown cannot be - the recommendation, highlighted as
/// the takeaway it is, and "Plan this", which sends the advisor's plan-able
/// sentence through the normal chat pipeline. The planner parses it, the
/// validator gates it, and the advice itself still never edits the plan.
class AdviceCardWidget extends StatelessWidget {
  /// The payload of the `advice_card` [ChatAction]: topic, recommendation,
  /// options, reasons, nextStep, planBrief, basis (see chat_screen's
  /// `_adviceCardFor`). Only the recommendation and planBrief are rendered;
  /// the rest rides along so the card can grow without a persistence
  /// migration.
  final Map<String, dynamic> payload;

  /// Called when "Plan this" is pressed. Null (or an empty `planBrief`)
  /// hides the button: advice on a standing plan has nothing to re-plan.
  final VoidCallback? onPlanThis;

  const AdviceCardWidget({super.key, required this.payload, this.onPlanThis});

  String get _recommendation => '${payload['recommendation'] ?? ''}';

  String get _planBrief => '${payload['planBrief'] ?? ''}'.trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_recommendation.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('advice-card'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
        boxShadow: [
          BoxShadow(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
            blurRadius: 0,
            spreadRadius: 0.8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.tips_and_updates_outlined,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Design advice',
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // THE RECOMMENDATION, highlighted: the lead the advisor's contract
          // promises, given the visual weight bold text alone never gave it.
          // No second label here - the markdown above already says "What I
          // would do"; the card shows the sentence as the takeaway, and the
          // options and trade-offs stay in the markdown too, so nothing
          // renders twice.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(AppTheme.rMd),
            ),
            child: Text(
              _recommendation,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_planBrief.isNotEmpty && onPlanThis != null) ...[
            const SizedBox(height: 10),
            // "Plan this" is a normal chat turn in the user's voice: the
            // planner parses it, the validator gates it, the same build card
            // appears as if it had been typed. Advice proposes; the user
            // sends; nothing here edits a plan by itself.
            FilledButton.icon(
              key: const ValueKey('advice-plan-this'),
              onPressed: onPlanThis,
              icon: const Icon(Icons.add_chart_outlined, size: 18),
              label: const Text('Plan this'),
            ),
          ],
        ],
      ),
    );
  }
}
