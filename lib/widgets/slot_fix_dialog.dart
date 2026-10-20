import 'package:flutter/material.dart';

/// The prompt behind a tap-to-fix chip: one field carrying the value that is
/// wrong, and the two ways out.
///
/// It owns its own controller rather than borrowing one from the caller:
/// the dialog route keeps animating - and keeps listening to its field -
/// after [showDialog] hands the result back, so a controller disposed by the
/// caller is a controller used after dispose. The widget test caught that.
class SlotFixDialog extends StatefulWidget {
  const SlotFixDialog({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  State<SlotFixDialog> createState() => _SlotFixDialogState();
}

class _SlotFixDialogState extends State<SlotFixDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Fix the ${widget.label}'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.value,
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Fix it'),
        ),
      ],
    );
  }
}
