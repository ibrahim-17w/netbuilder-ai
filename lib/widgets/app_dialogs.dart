import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Copy text and say so. Every artifact in this app ends up in a device or a
/// file, so copying is the action that matters most; a silent copy is a
/// button a user presses twice.
Future<void> copyText(
  BuildContext context,
  String text, {
  String message = 'Copied to the clipboard',
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// Show generated config, JSON or a report: monospaced, selectable, scrollable
/// and copyable, with an optional save-to-file action supplied by the caller.
Future<void> showArtifactDialog(
  BuildContext context, {
  required String title,
  required String text,
  String subtitle = '',
  String copyLabel = 'Copy',
  List<Widget> actions = const [],
}) {
  final theme = Theme.of(context);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(AppTheme.s24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 900,
          maxHeight: 640,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.s20,
                AppTheme.s16,
                AppTheme.s8,
                AppTheme.s8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        if (subtitle.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: Container(
                width: double.infinity,
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.35,
                ),
                padding: const EdgeInsets.all(AppTheme.s16),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(AppTheme.s12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ...actions,
                  const SizedBox(width: AppTheme.s8),
                  OutlinedButton.icon(
                    onPressed: () => copyText(dialogContext, text),
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: Text(copyLabel),
                  ),
                  const SizedBox(width: AppTheme.s8),
                  FilledButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Show a list of lines as a result - validator findings, planner
/// suggestions, blockers, probe output.
Future<void> showLinesDialog(
  BuildContext context, {
  required String title,
  required List<String> lines,
  String subtitle = '',
  IconData icon = Icons.fact_check_outlined,
  bool warn = false,
}) {
  final theme = Theme.of(context);
  final body = lines.isEmpty ? ['Nothing to report.'] : lines;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(
        icon,
        color: warn ? theme.colorScheme.error : theme.colorScheme.primary,
      ),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (subtitle.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.s8),
                child: Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final line in body)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 6, right: 8),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.7,
                                  ),
                                ),
                              ),
                            ),
                            Expanded(child: SelectableText(line)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => copyText(dialogContext, body.join('\n')),
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// A prompt for one line of text. Used where a value has no natural home on a
/// screen but is needed to complete an action (a file name, a search query).
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String label = '',
  String initial = '',
  String hint = '',
  String helper = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: label.isEmpty ? null : label,
          hintText: hint.isEmpty ? null : hint,
          helperText: helper.isEmpty ? null : helper,
          helperMaxLines: 3,
        ),
        onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('OK'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// A yes/no gate for the actions that change something outside the app.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = 'Run it',
  IconData icon = Icons.warning_amber_rounded,
  bool danger = false,
}) async {
  final theme = Theme.of(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(icon, color: danger ? theme.colorScheme.error : null),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Text(body),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Run something that talks to a service and show the outcome, with the
/// failure text verbatim - the same rule the rest of the app follows, because
/// "it failed" is not a message anyone can act on.
Future<T?> runWithFeedback<T>(
  BuildContext context, {
  required String busyLabel,
  required Future<T> Function() action,
  String successLabel = '',
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(
    SnackBar(content: Text(busyLabel), duration: const Duration(seconds: 30)),
  );
  try {
    final result = await action();
    messenger?.hideCurrentSnackBar();
    if (successLabel.isNotEmpty) {
      messenger?.showSnackBar(
        SnackBar(content: Text(successLabel), behavior: SnackBarBehavior.floating),
      );
    }
    return result;
  } catch (error) {
    messenger?.hideCurrentSnackBar();
    final text = error
        .toString()
        .replaceFirst(RegExp(r'^Exception: '), '')
        .replaceFirst(RegExp(r'^FormatException: '), '');
    messenger?.showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
      ),
    );
    return null;
  }
}
