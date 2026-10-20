import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// "The assistant is working": three dots that breathe, next to the same
/// avatar an answer will use, so the wait is visibly the assistant's turn.
class TypingBubble extends StatefulWidget {
  const TypingBubble({super.key});

  @override
  State<TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The three breathing dots say "the assistant is working" only to the
    // eye. A screen reader gets the same sentence.
    return Semantics(
      container: true,
      label: 'The assistant is answering',
      liveRegion: true,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppTheme.s14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.s18),
                child: CircleAvatar(
                  radius: 14,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.smart_toy_outlined,
                    size: 15,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.s8),
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.s16),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.s12,
                    vertical: AppTheme.s10,
                  ),
                  decoration: BoxDecoration(
                    color: AppPalette.neutralFill(theme.colorScheme),
                    borderRadius: BorderRadius.circular(AppTheme.rLg),
                    border: Border.all(
                      color: AppPalette.hairline(theme.colorScheme),
                    ),
                  ),
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 3; i++) ...[
                          if (i > 0) const SizedBox(width: AppTheme.s4),
                          Opacity(
                            // Each dot peaks a third of a cycle later than the
                            // last: the pulse reads as motion, not as a blink.
                            opacity:
                                0.3 +
                                0.7 *
                                    (1 -
                                            (((_controller.value + i / 3) % 1) -
                                                        0.5)
                                                    .abs() /
                                                0.5)
                                        .clamp(0, 1),
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurfaceVariant,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pill that appears when the transcript is scrolled away from the
/// newest message. It says how much is waiting, because "jump to latest"
/// does not tell you whether it is worth tapping.
class JumpToLatest extends StatelessWidget {
  final int unseen;
  final VoidCallback onTap;

  const JumpToLatest({super.key, required this.unseen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 2,
      color: theme.colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.s14,
            vertical: AppTheme.s8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unseen > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.s6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.inversePrimary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$unseen',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.s6),
              ],
              Text(
                unseen > 0 ? 'new' : 'Latest',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppTheme.s4),
              Icon(
                Icons.arrow_downward,
                size: 14,
                color: theme.colorScheme.onInverseSurface,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
