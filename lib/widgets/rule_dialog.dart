import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The dialog behind "Remember as a rule": the text is editable before it is
/// saved, because an answer is prose and a rule has to be an instruction the
/// planner can actually follow.
class RuleDialog extends StatefulWidget {
  final String initial;

  const RuleDialog({super.key, required this.initial});

  @override
  State<RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<RuleDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: _distil(widget.initial),
  );

  /// Keep the first sentence or two: a rule is read by the planner on every
  /// turn, so it has to be short enough to be worth its tokens.
  static String _distil(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 240) return text;
    final cut = text.substring(0, 240);
    final stop = cut.lastIndexOf('. ');
    return stop > 40 ? cut.substring(0, stop + 1) : '$cut...';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.bookmark_add_outlined),
      title: const Text('Remember this as a rule'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Rules are read before every plan this app makes, so the next '
              'build already follows it. Edit it into one instruction.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.s12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'The rule',
                hintText:
                    'Always use /30 between routers and document the link',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save rule'),
        ),
      ],
    );
  }
}
