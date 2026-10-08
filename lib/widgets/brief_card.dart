import 'package:flutter/material.dart';

import '../models/design_brief.dart';
import '../services/design_brief_service.dart';
import '../theme/app_theme.dart';

/// The "what I know so far / what's still open" card: the conversation's
/// design brief, shown while the brief is being built so the user can SEE
/// the state instead of inferring it from whether a build button appeared.
///
/// Read-only in v1 - tap-to-fix slots comes later. The build decision is
/// made by the chat (a build card is only offered when the brief is
/// ready); this card explains that state either way.
class BriefCardWidget extends StatelessWidget {
  final DesignBrief brief;

  const BriefCardWidget({super.key, required this.brief});

  @override
  Widget build(BuildContext context) {
    if (brief.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final open = brief.missing;
    final criticalOpen = brief.missingCritical;

    return Container(
      key: const ValueKey('brief-card'),
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
                brief.ready ? Icons.checklist : Icons.edit_note_outlined,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Design brief',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final id in DesignBrief.slotIds)
            if (brief.has(id)) _factRow(context, id, brief.facts[id]!),
          if (open.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Still open',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final id in open)
                  Container(
                    key: ValueKey('brief-open-$id'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: criticalOpen.contains(id)
                          ? scheme.tertiaryContainer.withValues(alpha: 0.6)
                          : scheme.surfaceContainerHighest.withValues(
                              alpha: 0.55,
                            ),
                      borderRadius: BorderRadius.circular(AppTheme.rSm),
                    ),
                    child: Text(
                      DesignBriefService.labelFor(id).toLowerCase(),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: criticalOpen.contains(id)
                            ? scheme.onTertiaryContainer
                            : scheme.onSurfaceVariant,
                        fontWeight: criticalOpen.contains(id)
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            brief.ready
                ? 'Enough to build - the planner has safe defaults for the '
                      'rest. Say the word and I will compile it.'
                : 'I will ask about the highlighted items before planning '
                      'anything - nothing is built until you say so.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _factRow(BuildContext context, String slotId, BriefFact fact) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              '${DesignBriefService.labelFor(slotId)}:',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: fact.display,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  if (fact.source.isNotEmpty)
                    TextSpan(
                      text: '  (${fact.source})',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
