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
/// actually made of - headings, bullets, fenced code, pipe tables, **bold**,
/// *italic*, `inline code` and [label](url) links. Anything else stays
/// literal, which is better than mangling it.
///
/// Precedence is fenced code > inline code > bold > italic: the inline scan
/// is positional and a code span that opens earlier consumes whatever
/// markdown-looking text follows inside it. There is deliberately no
/// `_underscore_` italic - between word characters (snake_case, device
/// names like `_token_`) an underscore is just text, and a rule that needs
/// boundary exceptions to stay literal is worse than no rule. Links do not
/// open anything: tapping one copies the URL, because everything in a
/// network answer ends up pasted somewhere.
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

  static final _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$');
  static final _bulletPattern = RegExp(r'^\s*(?:[-*+]|\d+\.)\s+(.*)$');
  static final _headingPrefix = RegExp(r'^(#{1,6})\s+');
  static final _bulletPrefix = RegExp(r'^\s*(?:[-*+]|\d+\.)\s+');

  /// Recent [parse] results keyed by source, so a finished bubble stops
  /// re-parsing on every rebuild while its neighbours stream in. The memo is
  /// bounded - a streaming answer is a new source string per chunk, so an
  /// unbounded map would keep every version of every answer alive for the
  /// life of the chat - evicting the least recently used entry at the limit.
  static final Map<String, List<MdBlock>> _parseMemo = {};
  static const int _parseMemoLimit = 64;

  static List<MdBlock> parse(String source) {
    final memoized = _parseMemo.remove(source);
    if (memoized != null) {
      _parseMemo[source] = memoized; // re-insert, so it leaves as most recent
      return memoized;
    }
    final blocks = _parse(source);
    if (_parseMemo.length >= _parseMemoLimit) {
      _parseMemo.remove(_parseMemo.keys.first);
    }
    _parseMemo[source] = blocks;
    return blocks;
  }

  static List<MdBlock> _parse(String source) {
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
      final heading = _headingPattern.firstMatch(line);
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
      final bullet = _bulletPattern.firstMatch(raw);
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
          !_headingPrefix.hasMatch(lines[i].trim()) &&
          !_bulletPrefix.hasMatch(lines[i])) {
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

  /// One positional scan over every inline construct. The alternatives are
  /// ordered so that when two could start at the same character, the richer
  /// one wins: a link consumes its own label and URL whole, bold is tried
  /// before italic (so `**x**` is never read as an empty italic followed by
  /// text), and a code span is matched even where bold would be, because a
  /// backtick and an asterisk can never start at the same character.
  static final _inlinePattern = RegExp(
    r'\[([^\]]+)\]\(([^)\s]+)\)'
    r'|\*\*(.+?)\*\*'
    r'|\*([^*\s](?:[^*]*[^*\s])?)\*'
    r'|`([^`]+)`',
  );

  /// A bare URL running right up to a match - `https://x.com/a*b*` - which
  /// must stay literal: those asterisks are part of the address, not
  /// emphasis. The link syntax protects its own URL by consuming it; this
  /// catches the ones that are plain text, by asking whether the address
  /// runs unbroken up to the match. Angle brackets are excluded from the
  /// address run, so a `>` visibly closes it and what follows is free to be
  /// emphasis.
  static final _bareUrlTail = RegExp(r'(?:https?|ftp)://[^\s<>]*$');

  /// Inline spans for `**bold**`, `*italic*`, `` `code` `` and
  /// `[label](url)`. [linkColor] tints and underlines the link (the theme
  /// primary, handed in by the caller). Matches inside an earlier code span,
  /// inside a link's URL, or inside a bare URL are never rendered as
  /// anything else - either the scan has already consumed them or the
  /// bare-URL guard keeps them verbatim.
  ///
  /// [onFilePathTap], when given, makes an inline-code span that reads as a
  /// `.pkt` file path tappable - the one place a chat answer is allowed to
  /// open something, because the chat that built the file is the most direct
  /// way to look at it.
  static List<InlineSpan> inline(
    String text,
    TextStyle base, {
    Color? linkColor,
    void Function(String path)? onFilePathTap,
  }) {
    final spans = <InlineSpan>[];
    final linkStyle = base.copyWith(
      color: linkColor,
      decoration: TextDecoration.underline,
      decorationColor: linkColor,
    );
    var cursor = 0;
    for (final match in _inlinePattern.allMatches(text)) {
      final label = match.group(1);
      final url = match.group(2);
      final bold = match.group(3);
      final italic = match.group(4);
      final code = match.group(5);
      // Not a link, and the UNCONSUMED text before it still reads as a bare
      // URL - `https://x.com/a*b*` - so the match sits inside the address.
      // Checking only the run since the last accepted match is what lets a
      // closed link protect its URL without smothering what comes after it:
      // the URL was consumed whole, so the emphasis that abuts its closing
      // paren is real emphasis again. Emitting nothing here keeps the match
      // literal - the plain run between [cursor] and the next accepted match
      // carries the characters through untouched.
      if (url == null &&
          _bareUrlTail.hasMatch(text.substring(cursor, match.start))) {
        continue;
      }
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      if (label != null && url != null) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ChatLinkSpan(label: label, url: url, style: linkStyle),
          ),
        );
      } else if (bold != null) {
        spans.add(TextSpan(
          text: bold,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else if (italic != null) {
        spans.add(TextSpan(
          text: italic,
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      } else if (code != null && onFilePathTap != null && isPktFilePath(code)) {
        // A built file's path is a control, not just text: the chat that
        // wrote it is the direct way to look at it. Rendered as a widget so
        // the tap is owned (and disposed) here, like [ChatLinkSpan].
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: ChatFilePathSpan(
              path: code,
              style: TextStyle(
                fontFamily: 'monospace',
                backgroundColor: base.color?.withValues(alpha: 0.10),
                color: linkColor,
                decoration: TextDecoration.underline,
                decorationStyle: TextDecorationStyle.dotted,
                decorationColor: linkColor,
              ),
              onTap: () => onFilePathTap(code),
            ),
          ),
        );
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

  /// Whether an inline-code span reads as a `.pkt` file path worth tapping.
  ///
  /// Deliberately narrow: it needs a path separator, so a bare backup name
  /// like `lab-20261007.pkt` inside prose stays inert text (the build card's
  /// own buttons own those), and it needs to end in `.pkt` so subnet tables
  /// in code style never become buttons.
  static bool isPktFilePath(String code) {
    final t = code.trim();
    if (t.length < 6) return false;
    if (!t.toLowerCase().endsWith('.pkt')) return false;
    return t.contains('/') || t.contains('\\');
  }
}

/// One tappable `` `C:\...\lab.pkt` `` inline-code span.
///
/// What the tap DOES is decided by the chat screen (open in Packet Tracer
/// when it is installed, the built-in viewer when it is not); this widget
/// only owns the gesture and says so to a screen reader. Public so tests can
/// find it the way they find [ChatLinkSpan].
class ChatFilePathSpan extends StatelessWidget {
  final String path;
  final TextStyle style;
  final VoidCallback onTap;

  const ChatFilePathSpan({
    super.key,
    required this.path,
    required this.style,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open $path',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Text(path, style: style),
      ),
    );
  }
}

/// Renders a chat answer: headings, bullets, fenced code, pipe tables.
class ChatMarkdownView extends StatelessWidget {
  final String source;
  final TextStyle? style;

  /// Called when a `.pkt` file path in inline code is tapped (see
  /// [ChatMarkdown.isPktFilePath]). Null leaves paths as inert styled text.
  final void Function(String path)? onFilePathTap;

  const ChatMarkdownView({
    super.key,
    required this.source,
    this.style,
    this.onFilePathTap,
  });

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
    // Links take the theme primary and an underline, so a link is a link in
    // a heading, a bullet, a table cell and a paragraph alike.
    final linkColor = Theme.of(context).colorScheme.primary;
    final onFilePathTap = this.onFilePathTap;
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
            children: ChatMarkdown.inline(block.text, base, linkColor: linkColor, onFilePathTap: onFilePathTap),
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
                TextSpan(
                  children: ChatMarkdown.inline(
                    block.text,
                    base,
                    linkColor: linkColor,
                    onFilePathTap: onFilePathTap,
                  ),
                ),
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
              // From the theme, not from the ink: the answer's own text colour
              // can be anything (white in a user bubble), and a black rule
              // around it disappears on a dark surface.
              color: Theme.of(context).colorScheme.outlineVariant,
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
                          children: ChatMarkdown.inline(
                            cell,
                            base,
                            linkColor: linkColor,
                            onFilePathTap: onFilePathTap,
                          ),
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
                          TextSpan(
                            children: ChatMarkdown.inline(
                              cell,
                              base,
                              linkColor: linkColor,
                              onFilePathTap: onFilePathTap,
                            ),
                          ),
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
          TextSpan(
            children: ChatMarkdown.inline(
              block.text,
              base,
              linkColor: linkColor,
              onFilePathTap: onFilePathTap,
            ),
          ),
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

/// One `[label](url)`, as a real widget so the tap can be owned properly.
///
/// Tapping copies the URL and says so - it does not open anything. A chat
/// about networks ends with commands pasted into devices, and this file
/// already made that the contract for code blocks; a link that yanked the
/// user out of the app mid-answer would be the one control here that
/// leaves it. The GestureDetector lives with the widget it belongs to, so
/// there is no recognizer created per build and left undisposed.
///
/// Public (rather than `_LinkSpan`) so tests can read [label] and [style]
/// off the rendered span without digging into its widget tree.
class ChatLinkSpan extends StatelessWidget {
  final String label;
  final String url;
  final TextStyle style;

  const ChatLinkSpan({
    super.key,
    required this.label,
    required this.url,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    void copyUrl() => copyText(context, url, message: 'Link copied');
    return Semantics(
      link: true,
      button: true,
      label: '$label (copies the link address)',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: copyUrl,
        child: Text(label, style: style),
      ),
    );
  }
}
