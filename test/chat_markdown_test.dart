import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/widgets/chat_markdown.dart';

void main() {
  test('a fenced block keeps its language and its exact body', () {
    final blocks = ChatMarkdown.parse(
      'Here is the fix:\n\n```cisco\nenable\nconfigure terminal\n```\n\nDone.',
    );
    expect(blocks.map((b) => b.kind).toList(), [
      MdKind.paragraph,
      MdKind.code,
      MdKind.paragraph,
    ]);
    final code = blocks[1];
    expect(code.language, 'cisco');
    expect(code.text, 'enable\nconfigure terminal');
    expect(blocks[0].text, 'Here is the fix:');
    expect(blocks[2].text, 'Done.');
  });

  test('a pipe table becomes a header and rows, without the rule row', () {
    final blocks = ChatMarkdown.parse(
      '| Device | IP |\n|---|---|\n| PC1 | 10.0.0.5 |\n| PC2 | 10.0.0.6 |\n',
    );
    expect(blocks, hasLength(1));
    final table = blocks.single;
    expect(table.kind, MdKind.table);
    expect(table.header, ['Device', 'IP']);
    expect(table.rows, hasLength(2));
    expect(table.rows.first, ['PC1', '10.0.0.5']);
    expect(table.rows.last, ['PC2', '10.0.0.6']);
  });

  test('headings, bullets and joined paragraphs', () {
    final blocks = ChatMarkdown.parse(
      '## What I found\n'
      '- PC1 has the wrong gateway\n'
      '- SW1 is missing a VLAN\n'
      '\n'
      'The link is\n'
      'up on both ends.\n',
    );
    expect(blocks.map((b) => b.kind).toList(), [
      MdKind.heading,
      MdKind.bullet,
      MdKind.bullet,
      MdKind.paragraph,
    ]);
    expect(blocks[0].level, 2);
    expect(blocks[0].text, 'What I found');
    expect(blocks[1].text, 'PC1 has the wrong gateway');
    expect(blocks[3].text, 'The link is up on both ends.',
        reason: 'a wrapped paragraph is one block');
  });

  test('a realistic answer round-trips every construct', () {
    const answer = '### Verdict\n'
        '\n'
        'The **subnet** is wrong on `PC1`.\n'
        '\n'
        '| Device | Gateway | Status |\n'
        '|---|---|---|\n'
        '| PC1 | 192.168.2.1 | wrong |\n'
        '| PC2 | 192.168.1.1 | ok |\n'
        '\n'
        'Fix:\n'
        '```\n'
        'ip route 0.0.0.0 0.0.0.0 192.168.1.1\n'
        '```\n';
    final blocks = ChatMarkdown.parse(answer);
    final kinds = blocks.map((b) => b.kind).toList();
    expect(kinds, [
      MdKind.heading,
      MdKind.paragraph,
      MdKind.table,
      MdKind.paragraph,
      MdKind.code,
    ]);
    expect(blocks[2].rows, hasLength(2));
    expect(blocks[4].text, 'ip route 0.0.0.0 0.0.0.0 192.168.1.1');
  });

  test('inline bold and code become spans, plain text stays plain', () {
    const base = TextStyle(fontSize: 14);
    final spans = ChatMarkdown.inline('**bold** and `code` and plain', base);
    expect(spans.map((s) => s.toPlainText()).toList(),
        ['bold', ' and ', 'code', ' and plain']);
    expect((spans[0] as TextSpan).style!.fontWeight, FontWeight.w700);
    expect((spans[2] as TextSpan).style!.fontFamily, 'monospace');
  });

  test('a single asterisk pair renders italic', () {
    const base = TextStyle(fontSize: 14);
    final spans = ChatMarkdown.inline('this is *quiet* emphasis', base);
    expect(spans.map((s) => s.toPlainText()).join(), 'this is quiet emphasis');
    final italics = spans
        .whereType<TextSpan>()
        .where((s) => s.style?.fontStyle == FontStyle.italic)
        .toList();
    expect(italics, hasLength(1));
    expect(italics.single.text, 'quiet');
  });

  test('bold wins where both could start, so **x** is never an empty italic',
      () {
    const base = TextStyle(fontSize: 14);
    final spans = ChatMarkdown.inline('**bold** then *later*', base);
    expect(spans.map((s) => s.toPlainText()).join(), 'bold then later');
    expect((spans.first as TextSpan).style!.fontWeight, FontWeight.w700);
    final italics = spans
        .whereType<TextSpan>()
        .where((s) => s.style?.fontStyle == FontStyle.italic)
        .toList();
    expect(italics, hasLength(1));
    expect(italics.single.text, 'later');
  });

  test('snake_case and device names keep their underscores literal', () {
    const base = TextStyle(fontSize: 14);
    // There is deliberately no _underscore_ italic: between word characters
    // an underscore is text, not markup.
    final spans = ChatMarkdown.inline('read _token_ from port_channel1',
        base);
    expect(spans, hasLength(1), reason: 'one plain run, nothing emphasized');
    expect(spans.single.toPlainText(), 'read _token_ from port_channel1');
    final span = spans.single as TextSpan;
    expect(span.style?.fontStyle, isNull);
    expect(span.style?.fontWeight, isNull);
  });

  test('a code span swallows markdown-looking text whole', () {
    const base = TextStyle(fontSize: 14);
    final spans = ChatMarkdown.inline('`*code* and **bold**`', base);
    expect(spans, hasLength(1));
    final code = spans.single as TextSpan;
    expect(code.text, '*code* and **bold**');
    expect(code.style!.fontFamily, 'monospace');
    expect(code.style!.fontStyle, isNull,
        reason: 'emphasis never fires inside a code span');
    expect(code.style!.fontWeight, isNull);
  });

  // A link renders as a tappable WidgetSpan, so a plain toPlainText() join
  // yields the object-replacement char where the label sits - the label
  // must be read off the span's ChatLinkSpan instead.
  String visibleText(InlineSpan s) =>
      s is WidgetSpan ? (s.child as ChatLinkSpan).label : s.toPlainText();

  test('a link becomes an underlined widget span carrying its label', () {
    const base = TextStyle(fontSize: 14);
    final spans =
        ChatMarkdown.inline('see [Cisco](https://cisco.com) docs', base);
    expect(spans.map(visibleText).join(), 'see Cisco docs');
    final link = spans.whereType<WidgetSpan>().single;
    final label = link.child as ChatLinkSpan;
    expect(label.label, 'Cisco');
    expect(label.style.decoration, TextDecoration.underline);
  });

  test('a link inside a code span stays literal code', () {
    const base = TextStyle(fontSize: 14);
    final spans = ChatMarkdown.inline('`[x](https://a.b)`', base);
    expect(spans, hasLength(1));
    final code = spans.single as TextSpan;
    expect(code.text, '[x](https://a.b)');
    expect(code.style!.fontFamily, 'monospace');
  });

  test('a closed link does not smother the emphasis that abuts it', () {
    const base = TextStyle(fontSize: 14);
    // The link consumed its own URL, so the bare-URL guard must not read
    // the address into what comes after the closing paren.
    final spans =
        ChatMarkdown.inline('[Cisco](https://cisco.com)*and more*', base);
    expect(spans.map(visibleText).join(), 'Ciscoand more');
    final italics = spans
        .whereType<TextSpan>()
        .where((s) => s.style?.fontStyle == FontStyle.italic)
        .toList();
    expect(italics, hasLength(1));
    expect(italics.single.text, 'and more');
  });

  test('asterisks inside a bare URL are not emphasis', () {
    const base = TextStyle(fontSize: 14);
    final spans = ChatMarkdown.inline('open https://x.com/a*b* now', base);
    expect(spans, hasLength(1));
    final span = spans.single as TextSpan;
    expect(span.toPlainText(), 'open https://x.com/a*b* now');
    expect(span.style?.fontStyle, isNull);
  });

  testWidgets('the widget paints a table and a code block', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatMarkdownView(
            source: '| A | B |\n|---|---|\n| 1 | 2 |\n\n```\nhello\n```\n',
          ),
        ),
      ),
    );
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.textContaining('hello'), findsOneWidget);
  });

  testWidgets('tapping a link copies the address and says so', (tester) async {
    // The clipboard is a platform channel; the test binding has no plugin
    // for it, so stand one in. What is under test is the tap -> copy ->
    // say-so chain, not the channel itself.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatMarkdownView(
            source: 'docs at [Cisco](https://cisco.com) here',
          ),
        ),
      ),
    );
    expect(find.text('Cisco'), findsOneWidget);

    await tester.tap(find.text('Cisco'));
    await tester.pumpAndSettle();
    expect(find.text('Link copied'), findsOneWidget);

    // The snackbar keeps a timer for its own dismissal; let it fire so the
    // test ends without a pending timer.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
