import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/chat_message.dart';
import '../services/settings_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// The message box and the suggestions that sit directly above it.
///
/// This is a leaf widget: it owns no conversation state. The screen supplies
/// the controller, focus node, attachments and callbacks, while the cards for
/// skills and plan questions are built by the screen and passed in ready to
/// display. That keeps the composition root in [ChatScreen] without making the
/// composer reach back into it for every action.
class ChatComposer extends StatelessWidget {
  final bool busy;
  final bool canCancelWhileBusy;
  final bool editing;
  final TextEditingController input;
  final FocusNode focusNode;
  final List<String> quickReplies;
  final List<ChatImage> pending;
  final Widget? skillMenu;
  final Widget? planPrompt;
  final VoidCallback onSend;
  final VoidCallback onCancelGeneration;
  final VoidCallback onOpenTools;
  final VoidCallback onCancelEdit;
  final ValueChanged<String> onQuickReply;
  final ValueChanged<ChatImage> onRemovePending;
  final VoidCallback onPickImage;
  final VoidCallback onAttachScreenshot;
  final VoidCallback onPickPkt;
  final VoidCallback onPaste;

  const ChatComposer({
    super.key,
    required this.busy,
    required this.editing,
    required this.input,
    required this.focusNode,
    required this.quickReplies,
    required this.pending,
    required this.onSend,
    required this.onCancelGeneration,
    required this.onOpenTools,
    required this.onCancelEdit,
    required this.onQuickReply,
    required this.onRemovePending,
    required this.onPickImage,
    required this.onAttachScreenshot,
    required this.onPickPkt,
    required this.onPaste,
    this.skillMenu,
    this.planPrompt,
    this.canCancelWhileBusy = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < 600;
    // The real platform capability, not defaultTargetPlatform: the widget-test
    // binding reports android for every test. This is the same switch the
    // phone's offline builder and engine paths use.
    final mobile = SettingsService.isMobile;
    // On a phone the keyboard can take half the screen. While it is open the
    // suggestions are hidden: they were pushing the field up and leaving the
    // person typing into a box with almost no room left.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    // A landscape phone leaves the opening screen about a hundred pixels for
    // the box. Suggestion chips there cost more than they give: the welcome
    // screen above already carries them and scrolls.
    final shortScreen = MediaQuery.sizeOf(context).height < 420;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          narrow ? 8 : 12,
          shortScreen ? 2 : 4,
          narrow ? 8 : 12,
          shortScreen ? 4 : (narrow ? 8 : 10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (editing)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.s6),
                child: Material(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(AppTheme.rMd),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: scheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Editing your message. Sending replaces this turn.',
                            style: TextStyle(
                              color: scheme.onSecondaryContainer,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: onCancelEdit,
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // The "/" menu: what the app can do, while a command is being
            // typed. It sits closest to the box because it is about the very
            // next keystroke.
            if (skillMenu != null)
              KeyedSubtree(
                key: const ValueKey('skill-menu'),
                child: skillMenu!,
              ),
            // A plan question waiting on an answer - the headcount a brief
            // stated versus the PCs it listed, for one - sits directly above
            // the box as a short list of options, so it is read and answered
            // where the next message would be typed.
            if (planPrompt != null)
              KeyedSubtree(
                key: const ValueKey('plan-prompt'),
                child: planPrompt!,
              ),
            // The assistant's own suggestions, as one-tap chips: a chat where
            // the answer is "say \"use ospf\"" should make that a button, not
            // a typing exercise.
            if (skillMenu == null &&
                quickReplies.isNotEmpty &&
                !busy &&
                !((mobile && keyboardOpen) || shortScreen))
              Padding(
                key: const ValueKey('quick-replies'),
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // Each chip is a suggested NEXT MESSAGE, not a label:
                    // a screen reader hears what tapping it will do.
                    for (final quick in quickReplies.take(4))
                      Semantics(
                        label: 'Suggested next step: $quick',
                        button: true,
                        onTap: () => onQuickReply(quick),
                        child: ExcludeSemantics(
                          child: ActionChip(
                            avatar: const Icon(Icons.bolt_outlined, size: 15),
                            label: Text(
                              quick,
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () => onQuickReply(quick),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (pending.isNotEmpty)
              Padding(
                key: const ValueKey('pending-chips'),
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final image in pending)
                      InputChip(
                        avatar: const Icon(Icons.image_outlined, size: 16),
                        label: Text(
                          image.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onDeleted: () => onRemovePending(image),
                      ),
                  ],
                ),
              ),
            // One unified composer capsule - field, attach and send inside a
            // single rounded surface, the way a modern chat input reads. A
            // focus ring (a tinted border plus a soft glow) says "I am
            // listening" the moment the field takes the caret.
            AnimatedBuilder(
              animation: focusNode,
              builder: (context, _) {
                final focused = focusNode.hasFocus;
                return AnimatedContainer(
                  key: const ValueKey('composer-capsule'),
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
                  decoration: BoxDecoration(
                    color: AppPalette.raised(scheme),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: focused
                          ? scheme.primary.withValues(alpha: 0.55)
                          : AppPalette.hairline(scheme),
                      width: focused ? 1.4 : 1,
                    ),
                    boxShadow: focused
                        ? [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.12),
                              blurRadius: 16,
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // One media picker, the way a chat app has one: every way
                      // of attaching something lives behind it, and the chat keeps
                      // its space.
                      PopupMenuButton<String>(
                        tooltip: 'Attach',
                        icon: const Icon(Icons.add_circle_outline),
                        onSelected: (value) {
                          if (value == 'image') {
                            onPickImage();
                          } else if (value == 'screenshot') {
                            onAttachScreenshot();
                          } else if (value == 'pkt') {
                            onPickPkt();
                          } else if (value == 'paste') {
                            onPaste();
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'image',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.add_photo_alternate_outlined),
                              title: Text('Photo or image file'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'screenshot',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.photo_library_outlined),
                              title: Text('Screenshot from the run'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'pkt',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.router_outlined),
                              title: Text('Packet Tracer save (.pkt)'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'paste',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.content_paste),
                              title: Text('Paste clipboard text'),
                            ),
                          ),
                        ],
                      ),
                      Expanded(
                        // A HARDWARE ENTER SENDS; SHIFT+ENTER ADDS A LINE.
                        // CallbackShortcuts sits closer to the field than the
                        // app-wide text-editing shortcuts, so it wins for a
                        // bare Enter while Shift+Enter falls through to the
                        // default newline. The IME action is a newline (see
                        // below), because on Android it used to replace the
                        // Return key with Send - so a multi-line brief could
                        // not be written on a phone at all.
                        child: CallbackShortcuts(
                          bindings: <ShortcutActivator, VoidCallback>{
                            const SingleActivator(LogicalKeyboardKey.enter):
                                onSend,
                            const SingleActivator(
                              LogicalKeyboardKey.numpadEnter,
                            ): onSend,
                          },
                          child: TextField(
                            controller: input,
                            focusNode: focusNode,
                            // NEVER DISABLED WHILE THE ASSISTANT ANSWERS. The box
                            // used to lock the moment a turn started, so a thought
                            // that arrived mid-answer had to be remembered by the
                            // user instead of written down. A disabled field also
                            // swallows the caret and the Android keyboard, which
                            // reads as "the app is broken" rather than "busy".
                            autofocus: true,
                            minLines: 1,
                            // A phone gets fewer visible lines: six rows plus
                            // the chips and the keyboard left the transcript
                            // with almost nothing. A landscape phone gets two:
                            // a long restored draft otherwise grew the box
                            // until the opening screen overflowed. The text
                            // still scrolls inside the field.
                            maxLines: shortScreen
                                ? 2
                                : narrow
                                ? 4
                                : 6,
                            // On a touch platform the IME action key inserts a
                            // newline: Android used to replace Return with Send,
                            // so a multi-line brief could not be written. A
                            // desktop keyboard keeps Send, because there Enter
                            // is the shortcut above and the action only backs
                            // the synthetic submit path.
                            textInputAction: mobile
                                ? TextInputAction.newline
                                : TextInputAction.send,
                            // Keep the caret clear of the keyboard when the
                            // field scrolls into view.
                            scrollPadding: EdgeInsets.fromLTRB(
                              20,
                              20,
                              20,
                              mobile ? 96 : 20,
                            ),
                            decoration: InputDecoration(
                              // labelText gives the field a real accessible
                              // name; the hint teaches the shortcuts.
                              labelText: 'Message',
                              hintText: narrow || mobile
                                  ? 'Ask a question, or describe what to do'
                                  : 'Ask a question, or describe what to do '
                                        '(Enter sends - Shift+Enter = new line)',
                              // The capsule IS the field's surface: the fill and
                              // outline are removed so the input melts into it.
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                            // An explicit submit action still sends: some IMEs
                            // ignore the configured newline action, and the
                            // test harness delivers one. A real Android Return
                            // key sends newline (above), so this never turns
                            // "skip line" back into "send".
                            onSubmitted: (_) => onSend(),
                          ),
                        ),
                      ),
                      // Everything else the app can do, labelled, in one sheet.
                      IconButton(
                        tooltip: 'Tools: run, capture, and integrations',
                        icon: const Icon(Icons.tune),
                        onPressed: busy ? null : onOpenTools,
                      ),
                      const SizedBox(width: 2),
                      // The send button answers the composer: an empty box gets
                      // a quiet button, a written message gets the filled,
                      // glowing one. Driven by the controller, so only the
                      // button rebuilds on each keystroke - never the
                      // transcript.
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: input,
                        builder: (context, value, _) {
                          final hasText = value.text.trim().isNotEmpty;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            curve: Curves.easeOut,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: busy || hasText
                                  ? scheme.primary
                                  : scheme.surfaceContainerHighest,
                              boxShadow: busy || hasText
                                  ? [
                                      BoxShadow(
                                        color: scheme.primary.withValues(
                                          alpha: 0.30,
                                        ),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: IconButton.filled(
                              tooltip: busy
                                  ? canCancelWhileBusy
                                        ? 'Stop generating'
                                        : 'Saving requested change'
                                  : editing
                                  ? 'Update message'
                                  : 'Send',
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                foregroundColor: busy || hasText
                                    ? scheme.onPrimary
                                    : scheme.onSurfaceVariant,
                                elevation: 0,
                              ),
                              icon: busy
                                  ? canCancelWhileBusy
                                        ? const Icon(Icons.stop)
                                        : const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                  : const Icon(Icons.send),
                              onPressed: busy
                                  ? canCancelWhileBusy
                                        ? onCancelGeneration
                                        : null
                                  : (input.text.trim().isEmpty ? null : onSend),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
