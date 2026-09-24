import 'package:flutter/material.dart';
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
}
