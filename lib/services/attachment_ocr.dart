import '../models/chat_message.dart';

/// What the keyless chat could read out of this turn's attachments.
class OcrEvidence {
  /// True when at least one image produced text.
  final bool any;

  /// The display block for the reply (quoted text per image), or '' when
  /// nothing was readable.
  final String block;

  /// Why nothing could be read, in plain words, or '' when something was.
  final String note;

  const OcrEvidence({this.any = false, this.block = '', this.note = ''});
}

/// Reads attached screenshots with the engine's Tesseract so a keyless
/// conversation can still see them.
///
/// The extracted text is QUOTED, not interpreted: the offline corpus has no
/// picture understanding, and dressing OCR output up as an answer would be
/// the same invented confidence the rest of the app refuses. What the user
/// gets is the text, visibly labelled as machine-read, beside the normal
/// answer to whatever they typed.
class AttachmentOcr {
  const AttachmentOcr._();

  /// The same per-turn cap the model paths apply: more than three pictures
  /// in one message is a slideshow, not a question.
  static const int maxImages = 3;

  /// The longest quote one image contributes. A full-screen terminal dump is
  /// useful evidence; a wall of it is noise beside a chat reply.
  static const int maxCharsPerImage = 1200;

  static Future<OcrEvidence> read(
    List<ChatImage> attachments, {
    required Future<String> Function(ChatImage image) readBase64,
    required Future<String> Function(String base64) ocr,
  }) async {
    if (attachments.isEmpty) return const OcrEvidence();
    final quotes = <String>[];
    final failures = <String>[];
    for (final image in attachments.take(maxImages)) {
      final base64 = await readBase64(image);
      if (base64.isEmpty) {
        failures.add('${image.name}: the file could not be read');
        continue;
      }
      try {
        final text = _tidy(await ocr(base64));
        if (text.isEmpty) {
          quotes.add('_${image.name}: no readable text in this image._');
          continue;
        }
        quotes.add('**${image.name}** (machine-read):\n$text');
      } catch (e) {
        failures.add(
          '${image.name}: ${e.toString().replaceFirst('Exception: ', '')}',
        );
      }
    }
    if (quotes.isEmpty) {
      return OcrEvidence(
        note:
            'I could not read the attached image(s) here '
            '(${failures.join('; ')}). Screenshots need the local engine '
            'running (no API key), or a model key to look at them directly.',
      );
    }
    final block =
        '**Read from your screenshot(s) - machine-read text, '
        'check it before relying on it:**\n\n${quotes.join('\n\n')}'
        '${failures.isEmpty ? '' : '\n\n(Not readable: ${failures.join('; ')}.)'}';
    return OcrEvidence(any: true, block: block);
  }

  /// Collapse blank runs and cap the length, cutting on a line boundary so
  /// the quote never ends mid-command.
  static String _tidy(String raw) {
    final text = raw.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    if (text.length <= maxCharsPerImage) return text;
    final cut = text.substring(0, maxCharsPerImage);
    final lastLine = cut.lastIndexOf('\n');
    return '${lastLine > maxCharsPerImage ~/ 2 ? cut.substring(0, lastLine) : cut}\n...';
  }
}
