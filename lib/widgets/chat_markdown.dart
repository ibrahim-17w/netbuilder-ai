import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_dialogs.dart';

/// What a block of chat text is.
enum MdKind { heading, paragraph, bullet, code, table }

/// One parsed block. The parse is pure and separate from the painting, so the
/// rules are unit-tested and the widget stays thin.
class MdBlock {
  final MdKind kind;
  final String text;
  final int level;
  final String language;
  final List<List<String>> rows;
  final List<String> header;

  const MdBlock({
    required this.kind,
    this.text = '',
    this.level = 0,
    this.language = '',
    this.rows = const [],
    this.header = const [],
  });
}

/// A small, deliberate subset of Markdown: the things a network answer is
/// actually made of - headings, bullets, fenced code, pipe tables, **bold**
/// and `inline code`. Anything else stays literal, which is better than
/// mangling it.
class ChatMarkdown {
  const ChatMarkdown._();

  static bool _isRule(String line) {
    final t = line.trim();
    if (t.length < 3) return false;
    return t.split('').every((c) => c == '-' || c == ':' || c == '|' || c == ' ');
  }

  static bool _isTableRow(String line) {
    final t = line.trim();
    return t.startsWith('|') && t.endsWith('|') && t.length > 2;
  }

  static List<String> _cells(String line) {
    var t = line.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    return t.split('|').map((c) => c.trim()).toList();
  }

  static List<MdBlock> parse(String source) {
    final blocks = <MdBlock>[];
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    var i = 0;

    while (i < lines.length) {
      final raw = lines[i];
      final line = raw.trimRight();

      if (line.trim().isEmpty) {
        i++;
        continue;
      }

      // ``` fenced code
      if (line.trimLeft().startsWith('```')) {
        final language = line.trim().substring(3).trim();
        i++;
        final body = <String>[];
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          body.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // closing fence
        blocks.add(MdBlock(
          kind: MdKind.code,
          text: body.join('\n'),
          language: language,
        ));
        continue;
      }

      // | a | b |  with a |---|---| rule underneath
      if (_isTableRow(line) &&
          i + 1 < lines.length &&
          _isRule(lines[i + 1]) &&
          lines[i + 1].contains('-')) {
        final header = _cells(line);
        i += 2; // header + rule
        final rows = <List<String>>[];
        while (i < lines.length && _isTableRow(lines[i])) {
          rows.add(_cells(lines[i]));
          i++;
        }
        blocks.add(MdBlock(kind: MdKind.table, header: header, rows: rows));
        continue;
      }

      // heading
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        blocks.add(MdBlock(
          kind: MdKind.heading,
          level: heading.group(1)!.length,
          text: heading.group(2)!.trim(),
        ));
        i++;
        continue;
      }

      // bullet
      final bullet = RegExp(r'^\s*(?:[-*+]|\d+\.)\s+(.*)$').firstMatch(raw);
      if (bullet != null) {
        blocks.add(MdBlock(kind: MdKind.bullet, text: bullet.group(1)!.trim()));
        i++;
        continue;
      }

      // paragraph: join until a blank line or another construct
      final paragraph = <String>[line.trim()];
      i++;
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          !lines[i].trimLeft().startsWith('```') &&
          !_isTableRow(lines[i]) &&
          !RegExp(r'^(#{1,6})\s+').hasMatch(lines[i].trim()) &&
          !RegExp(r'^\s*(?:[-*+]|\d+\.)\s+').hasMatch(lines[i])) {
        paragraph.add(lines[i].trim());
        i++;
      }
      blocks.add(MdBlock(
        kind: MdKind.paragraph,
        text: paragraph.join(' '),
      ));
    }
    return blocks;
  }

  /// Inline spans for `**bold**` and `` `code` ``.
  static List<InlineSpan> inline(String text, TextStyle base) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final bold = match.group(1);
      final code = match.group(2);
      if (bold != null) {
        spans.add(TextSpan(
          text: bold,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else if (code != null) {
        spans.add(TextSpan(
          text: code,
          style: TextStyle(
            fontFamily: 'monospace',
            backgroundColor: base.color?.withValues(alpha: 0.10),
          ),
        ));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }
}

/// Renders a chat answer: headings, bullets, fenced code, pipe tables.
class ChatMarkdownView extends StatelessWidget {
  final String source;
  final TextStyle? style;

  const ChatMarkdownView({super.key, required this.source, this.style});

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final blocks = ChatMarkdown.parse(source);
    if (blocks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
            child: _block(context, blocks[i], base),
          ),
      ],
    );
  }

  Widget _block(BuildContext context, MdBlock block, TextStyle base) {
    switch (block.kind) {
      case MdKind.heading:
        final size = switch (block.level) {
          1 => 1.35,
          2 => 1.2,
          3 => 1.1,
          _ => 1.0,
        };
        return Text.rich(
          TextSpan(
            children: ChatMarkdown.inline(block.text, base),
            style: base.copyWith(
              fontSize: (base.fontSize ?? 14) * size,
              fontWeight: FontWeight.w700,
            ),
          ),
        );

      case MdKind.bullet:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('\u2022  ', style: base),
            Expanded(
              child: Text.rich(
                TextSpan(children: ChatMarkdown.inline(block.text, base)),
                style: base,
              ),
            ),
          ],
        );

      case MdKind.code:
        return _CodeBlock(block: block, base: base);

      case MdKind.table:
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(
              color: (base.color ?? Colors.black).withValues(alpha: 0.20),
              width: 0.6,
            ),
            children: [
              TableRow(
                children: [
                  for (final cell in block.header)
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text.rich(
                        TextSpan(
                          children: ChatMarkdown.inline(cell, base),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        style: base,
                      ),
                    ),
                ],
              ),
              for (final row in block.rows)
                TableRow(
                  children: [
                    for (final cell in row)
                      Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text.rich(
                          TextSpan(children: ChatMarkdown.inline(cell, base)),
                          style: base,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );

      case MdKind.paragraph:
        return Text.rich(
          TextSpan(children: ChatMarkdown.inline(block.text, base)),
          style: base,
        );
    }
  }
}

/// A fenced block: the language, the code, and one button that copies exactly
/// what is in it.
///
/// Copying is the whole point of a config in a chat answer - the next action
/// is always pasting it into a device or a file - and a block that has to be
/// selected by dragging across a horizontal scroll is a block people mistype.
class _CodeBlock extends StatelessWidget {
  final MdBlock block;
  final TextStyle base;

  const _CodeBlock({required this.block, required this.base});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.s12,
                  AppTheme.s6,
                  AppTheme.s6,
                  AppTheme.s6,
                ),
                child: Text(
                  block.language.isEmpty ? 'config' : block.language,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => copyText(
                  context,
                  block.text,
                  message: 'Copied the ${block.language.isEmpty ? 'block' : block.language} '
                      'commands',
                ),
                icon: const Icon(Icons.copy_all_outlined, size: 14),
                label: const Text('Copy'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onSurfaceVariant,
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              const SizedBox(width: AppTheme.s6),
            ],
          ),
          Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.6)),
          Padding(
            padding: const EdgeInsets.all(AppTheme.s12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                block.text,
                style: base.copyWith(
                  fontFamily: 'monospace',
                  fontSize: (base.fontSize ?? 14) - 1,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
