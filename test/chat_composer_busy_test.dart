import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/screens/chat_screen.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:provider/provider.dart';

/// The composer stays usable while the assistant is answering.
///
/// This pins the reported bug: the message box and the attach menu were both
/// disabled (`enabled: !_busy`) the moment a turn started, so anything the
/// user thought of mid-answer had to be held in their head instead of typed
/// into the box that was right there.
///
/// HOW THE BUSY STATE IS FORCED, and why it is forced this way: `_busy` lives
/// in a private field of a private State class, a widget test cannot set it
/// directly, and the screen exposes no "set busy" API. Driving it through the
/// model would mean a live provider, real network or the sidecar - all three
/// of which this harness must not touch for a deterministic run. So the turn
/// is parked on the store instead: `MemoryService.logChat` is overridden with
/// a Future that never completes, which leaves the screen in exactly the
/// interesting state - the user's turn is on the transcript, the assistant
/// still owes an answer, the send button is already a Stop button - for as
/// long as the test needs. Nothing polls a clock and nothing opens a socket,
/// so that state cannot drift out from under the assertions.
class _FakeSettings extends SettingsService {
  @override
  Future<String?> getApiKey() async => '';
  @override
  Future<String?> getOpenAiKey() async => '';
}

/// A store whose log write never finishes, over a transcript that already
/// holds an advice card. The advice card is the one control in the chat that
/// reaches `_sendQuickReply` WITHOUT a `_busy ? null :` guard on its button,
/// so it is the route a suggestion can still be tapped from during a turn.
class _ParkingStore extends MemoryService {
  final _never = Completer<void>();

  @override
  bool get ready => true;

  @override
  Future<List<ChatMessage>> recentChat({
    int limit = 5000,
    String conversation = '',
  }) async => const [
    ChatMessage(
      role: 'user',
      text: 'how many access points do i need for 40 users?',
      createdAt: '2026-10-08T10:00:00.000',
    ),
    ChatMessage(
      role: 'model',
      text: 'Wired access points beat mesh for anything larger than a flat.',
      createdAt: '2026-10-08T10:00:01.000',
      actions: [
        ChatAction(
          kind: 'advice_card',
          summary: 'Design advice',
          payload: {
            'topic': 'ap_selection',
            'recommendation': 'Wired access points beat mesh.',
            'planBrief': 'Build a small office with 2 wireless routers and '
                '30 PCs',
            'basis': 'the lab on the table',
          },
        ),
      ],
    ),
  ];

  @override
  Future<List<Map<String, dynamic>>> conversations({
    int limit = 200,
    String query = '',
  }) async => const [];

  @override
  Future<Map<String, dynamic>?> conversationMeta(String id) async => const {
    'id': 'default',
    'title': 'Lab',
    'project': '',
    'summary': '',
    'stateJson': '{}',
  };

  @override
  Future<List<Map<String, dynamic>>> recentChanges({
    String conversation = '',
    String device = '',
    int limit = 50,
  }) async => const [];

  @override
  Future<int> logChat(
    ChatMessage message, {
    String conversation = 'default',
  }) async => _never.future.then((_) => 1);

  @override
  Future<void> ensureConversation(
    String id, {
    String project = '',
    String title = '',
  }) async {}

  @override
  Future<void> setSessionState(String id, String stateJson) async {}
}

Widget _chat() => MultiProvider(
  providers: [
    ChangeNotifierProvider<SettingsService>.value(value: _FakeSettings()),
    ChangeNotifierProvider<MemoryService>.value(value: _ParkingStore()),
  ],
  child: const MaterialApp(home: Scaffold(body: ChatScreen())),
);

/// Mount the chat on a tall surface.
///
/// On the default 800x600 the seeded advice card's button lands underneath
/// the composer, so a real tap there hits the message box instead and the
/// test would only "pass" because nothing happened (the draft-protection
/// test passes vacuously on a missed tap). The drawer test in
/// `test/chat_conversations_test.dart` gets its room the same way. How tall
/// the sheet is is not what this file is about - the draft is.
Future<void> _pumpChat(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_chat());
  await tester.pumpAndSettle();
}

/// The message field, found by its label rather than by position: the
/// composer is the one field a person always means when they say "the box".
Finder _composer() => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == 'Message',
);

Finder _attach() => find.byType(PopupMenuButton<String>);

/// What the field is really made of, below the TextField wrapper.
Finder _editable() => find.descendant(
  of: _composer(),
  matching: find.byType(EditableText),
);

String _draft(WidgetTester tester) =>
    tester.widget<TextField>(_composer()).controller!.text;

/// Send a turn and leave it in flight, so the screen stays busy for the rest
/// of the test. Bounded pumps rather than `pumpAndSettle`: with the store
/// write parked there is nothing left to settle, and the indeterminate
/// progress bar a busy turn carries never settles anyway.
Future<void> _sendAndPark(WidgetTester tester, String text) async {
  await tester.enterText(_composer(), text);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Bounded pumping for anything that happens while a turn is running.
Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Put the top of the transcript back on screen.
///
/// The transcript is a plain (non-reversed) `ListView`, and sending a turn
/// jumps it to the end, so the seeded advice card - the second of four turns -
/// leaves the cache extent and stops being built at all. A finder for it then
/// matches nothing, which is what `ensureVisible` reports as "No element".
///
/// A drag larger than the content clamps to offset 0, so the list ends up
/// exactly where a person scrolling up leaves it and the early turns sit at
/// the TOP of the viewport. `ensureVisible` would be wrong here: it scrolls
/// the minimum needed, which parks the card's button at the bottom edge,
/// underneath the composer - a tap there lands on the message box instead.
Future<void> _revealTranscriptTop(WidgetTester tester) async {
  await tester.drag(find.byType(ListView).first, const Offset(0, 100000));
  await tester.pump();
  expect(_planThis(), findsOneWidget,
      reason: 'the seeded advice card must be back on screen');
}

Finder _planThis() => find.byKey(const ValueKey('advice-plan-this'));

void main() {
  testWidgets('the send button becomes Stop while a turn runs', (tester) async {
  await _pumpChat(tester);

    await _sendAndPark(tester, 'add a switch to it');

    // The affordance that already existed, and the premise of this whole
    // file: the turn is in flight, so the send button is a Stop button.
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);
  });

  testWidgets('the composer stays enabled while a turn runs', (tester) async {
  await _pumpChat(tester);

    await _sendAndPark(tester, 'add a switch to it');

    expect(
      tester.widget<TextField>(_composer()).enabled,
      isNot(false),
      reason: 'enabled: null means enabled; only an explicit false locks it',
    );
    // The same fact as the editing engine sees it - a disabled field is built
    // readOnly, so nothing typed could land in it at all.
    expect(
      tester.widget<EditableText>(_editable()).readOnly,
      isFalse,
      reason: 'a disabled box is built readOnly - this one is not',
    );
    // And the field takes the caret, which a locked-out box refuses to.
    await tester.showKeyboard(_composer());
    await tester.pump();
    expect(
      tester.widget<TextField>(_composer()).focusNode!.hasFocus,
      isTrue,
      reason: 'the user must be able to put the caret in the box mid-turn',
    );
  });

  testWidgets('text typed mid-turn survives, and a send attempt does not '
      'throw it away', (tester) async {
  await _pumpChat(tester);

    await _sendAndPark(tester, 'add a switch to it');

    // Typed while the assistant is still answering...
    await tester.enterText(_composer(), 'and give the DMZ its own VLAN');
    await tester.pump();
    expect(_draft(tester), 'and give the DMZ its own VLAN');

    // ...and still there after the user tries to send it: the send attempt
    // returns early while busy and leaves _input.text exactly as typed, so
    // the Enter they press the moment the turn ends goes out instead of
    // vanishing into a disabled box.
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(
      _draft(tester),
      'and give the DMZ its own VLAN',
      reason: 'a send made while busy must not drop the draft',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the attach menu stays usable while a turn runs', (tester) async {
  await _pumpChat(tester);

    await _sendAndPark(tester, 'add a switch to it');

    expect(
      tester.widget<PopupMenuButton<String>>(_attach()).enabled,
      isNot(false),
      reason: 'an attachment can be staged while the assistant answers',
    );

    // Not merely enabled: the menu opens, so the routes behind it can be
    // reached at all.
    await tester.tap(find.byTooltip('Attach'));
    await _pump(tester);
    expect(find.text('Photo or image file'), findsOneWidget);
    expect(find.text('Screenshot from the run'), findsOneWidget);

    // Closed again, so the tree is left as it was found.
    await tester.tapAt(const Offset(20, 20));
    await _pump(tester);
    expect(find.text('Photo or image file'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a suggestion tapped mid-turn keeps the draft instead of '
      'replacing it', (tester) async {
  await _pumpChat(tester);

    // The transcript is seeded with an advice card, so its "Plan this"
    // button is on screen - the one suggestion route with no busy guard.
    expect(_planThis(), findsOneWidget);

    await _sendAndPark(tester, 'add a switch to it');
    await tester.enterText(_composer(), 'the words i already typed');
    await tester.pump();
    await _revealTranscriptTop(tester);

    // The old code overwrote the composer with the suggestion and returned;
    // now the typed text is left exactly where the user left it.
    await tester.tap(_planThis());
    await _pump(tester);
    expect(
      _draft(tester),
      'the words i already typed',
      reason: 'a quick reply mid-turn must never overwrite the draft',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty composer still receives the suggestion, so the tap '
      'is not lost', (tester) async {
  await _pumpChat(tester);

    expect(_planThis(), findsOneWidget);

    await _sendAndPark(tester, 'add a switch to it');
    await tester.enterText(_composer(), '');
    await tester.pump();
    await _revealTranscriptTop(tester);

    // Nothing typed means nothing to protect: the suggestion waits in the
    // box, where the user can see it and send it as soon as the turn ends.
    // That is the feedback the silent early return never gave.
    await tester.tap(_planThis());
    await _pump(tester);
    expect(
      _draft(tester).trim(),
      isNotEmpty,
      reason: 'a suggestion tapped mid-turn must land somewhere visible',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shift+Enter still adds a line rather than sending mid-turn',
      (tester) async {
  await _pumpChat(tester);

    await _sendAndPark(tester, 'add a switch to it');

    await tester.enterText(_composer(), 'first line');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(
      _draft(tester),
      isNotEmpty,
      reason: 'Shift+Enter must add a line, not try to send',
    );
  });
}
