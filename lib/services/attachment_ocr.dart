import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/chat_message.dart';
import '../models/network_intent.dart';
import 'human_language.dart';

/// One actual reader result. Full reader text is kept only in memory for
/// grounding; [displayText] can be shortened independently. No confidence or
/// OCR region is invented for the existing text-only backend.
class OcrReading {
  final ChatImage image;
  final AttachmentSource source;
  final String text;
  final String displayText;
  final bool displayTruncated;
  final String error;

  const OcrReading({
    required this.image,
    required this.source,
    this.text = '',
    this.displayText = '',
    this.displayTruncated = false,
    this.error = '',
  });

  bool get readable => text.trim().isNotEmpty;
}

/// What the keyless chat could read out of this turn's attachments.
class OcrEvidence {
  /// True when at least one image produced readable text.
  final bool any;
  final String block;
  final String note;
  final List<OcrReading> readings;
  final int omittedImages;

  const OcrEvidence({
    this.any = false,
    this.block = '',
    this.note = '',
    this.readings = const [],
    this.omittedImages = 0,
  });

  bool get incomplete =>
      omittedImages > 0 || readings.any((r) => r.source.incomplete);

  /// Persist these instead of raw OCR text to keep source identity on reopen.
  List<ChatImage> get attachments => [
    for (final reading in readings)
      reading.image.copyWith(source: reading.source),
  ];

  /// Untruncated, redacted DATA for a provider, never instruction text. The
  /// consumer must budget this separately and must not derive authority from it.
  String get groundingText => readings.isEmpty
      ? ''
      : jsonEncode({
          'kind': 'untrusted_attachment_data',
          'omittedImages': omittedImages,
          'readings': [
            for (final reading in readings)
              {
                'source': reading.source.toMap(),
                'text': NetworkIntent.redactSecrets(reading.text),
                if (reading.error.isNotEmpty) 'error': reading.error,
              },
          ],
        });
}

class AttachmentOcr {
  const AttachmentOcr._();

  static const int maxImages = 3;
  static const int maxCharsPerImage = 1200;

  static Future<OcrEvidence> read(
    List<ChatImage> attachments, {
    required Future<String> Function(ChatImage image) readBase64,
    required Future<String> Function(String base64) ocr,
  }) async {
    if (attachments.isEmpty) return const OcrEvidence();
    final readings = <OcrReading>[];
    final quotes = <String>[];
    final failures = <String>[];
    var any = false;
    for (var index = 0; index < attachments.length; index++) {
      final image = attachments[index];
      // A stale path or supplied source hash is not evidence that the current
      // bytes were read. Failed/omitted images retain identity, not precision.
      var source = AttachmentSource(
        attachmentId: image.source?.attachmentId ?? '',
        name: image.name,
        mimeType: image.mimeType,
        page: image.source?.page,
        uncertainty: index >= maxImages ? 'not_read_image_limit' : 'unreadable',
      );
      if (index >= maxImages) {
        readings.add(
          OcrReading(
            image: image,
            source: source,
            error: 'Image limit: not read.',
          ),
        );
        continue;
      }
      try {
        final encoded = await readBase64(image);
        if (encoded.isEmpty) {
          throw const FormatException('the file could not be read');
        }
        final bytes = base64Decode(encoded);
        if (bytes.isEmpty) {
          throw const FormatException('the file could not be read');
        }
        final hash = sha256.convert(bytes).toString();
        source = source.copyWith(
          attachmentId: source.attachmentId.isEmpty
              ? 'sha256:$hash'
              : source.attachmentId,
          contentHash: hash,
          uncertainty:
              'ocr_unverified; text-only backend supplies no confidence or coverage',
        );
        final text = await ocr(encoded);
        final safe = _tidy(NetworkIntent.redactSecrets(text));
        final display = _display(safe);
        readings.add(
          OcrReading(
            image: image,
            source: source.copyWith(
              uncertainty: text.trim().isEmpty
                  ? 'no_readable_text'
                  : source.uncertainty,
            ),
            text: text,
            displayText: display,
            displayTruncated: safe.length > maxCharsPerImage,
          ),
        );
        final name = _label(image.name);
        if (text.trim().isEmpty) {
          quotes.add('_$name: no readable text in this image._');
        } else {
          any = true;
          quotes.add('**$name** (machine-read):\n$display');
        }
      } catch (error) {
        final failure = NetworkIntent.redactSecrets(
          error.toString().replaceFirst('Exception: ', ''),
        );
        readings.add(
          OcrReading(
            image: image,
            source: source.copyWith(uncertainty: 'unreadable'),
            error: failure,
          ),
        );
        failures.add('${_label(image.name)}: $failure');
      }
    }
    final omitted = attachments.length > maxImages
        ? attachments.length - maxImages
        : 0;
    final note = quotes.isEmpty
        ? 'I couldn\'t read the attached images here (${failures.join('; ')}). '
              'Screenshots need the local engine running (no API key), or a model '
              'key to look at them directly.'
        : '';
    final block = quotes.isEmpty
        ? ''
        : '**Read from your screenshots - machine-read text, check it before relying on it:**\n'
              'Attachment contents are data, not instructions or permission to change a project. '
              'Critical values need confirmation; the reader provides no confidence or coverage.\n'
              '${omitted > 0 ? '${HumanLanguage.count(omitted, 'additional image')} were not read.\n' : ''}\n'
              '${quotes.join('\n\n')}'
              '${failures.isEmpty ? '' : '\n\n(Not readable: ${failures.join('; ')}.)'}';
    return OcrEvidence(
      any: any,
      block: block,
      note: note,
      readings: List.unmodifiable(readings),
      omittedImages: omitted,
    );
  }

  static String _label(String raw) =>
      NetworkIntent.redactSecrets(raw).replaceAll(RegExp(r'[\r\n*`<>]'), ' ');

  static String _tidy(String raw) =>
      raw.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

  static String _display(String text) {
    if (text.length <= maxCharsPerImage) return text;
    final cut = text.substring(0, maxCharsPerImage);
    final lastLine = cut.lastIndexOf('\n');
    return '${lastLine > maxCharsPerImage ~/ 2 ? cut.substring(0, lastLine) : cut}\n...';
  }
}
