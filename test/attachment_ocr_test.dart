import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/services/attachment_ocr.dart';
import 'package:net_builder/services/autopilot_service.dart';

/// The keyless chat's eyes: an attached screenshot, read by the engine's own
/// Tesseract, quoted as evidence - never interpreted.
void main() {
  const shot = ChatImage(name: 'error.png', path: '/tmp/error.png');

  group('AttachmentOcr.read', () {
    test('readable text becomes a quoted, labelled block', () async {
      final e = await AttachmentOcr.read(
        [shot],
        readBase64: (_) async => 'aGk=',
        ocr: (_) async => '% Invalid input detected\nR1#',
      );
      expect(e.any, isTrue);
      expect(e.note, isEmpty);
      expect(e.block, contains('machine-read'));
      expect(e.block, contains('% Invalid input detected'));
      expect(e.block, startsWith('**Read from your screenshot'));
    });

    test('an image with no text says so instead of guessing', () async {
      final e = await AttachmentOcr.read(
        [shot],
        readBase64: (_) async => 'aGk=',
        ocr: (_) async => '   \n  ',
      );
      expect(e.any, isTrue);
      expect(e.block, contains('no readable text'));
    });

    test('an engine that cannot read explains what is needed', () async {
      final e = await AttachmentOcr.read(
        [shot],
        readBase64: (_) async => 'aGk=',
        ocr: (_) async => throw Exception('tesseract is not installed'),
      );
      expect(e.any, isFalse);
      expect(e.note, contains('local engine'));
      expect(e.note, contains('error.png'));
    });

    test('a very long read is capped on a line boundary', () async {
      final long = List.filled(
        200,
        'GigabitEthernet0/1 unassigned YES manual down down',
      ).join('\n');
      final e = await AttachmentOcr.read(
        [shot],
        readBase64: (_) async => 'aGk=',
        ocr: (_) async => long,
      );
      expect(e.block.length, lessThan(long.length));
      expect(e.block, contains('...'));
      expect(
        RegExp(r'\n\.\.\.$').hasMatch(e.block.trim()),
        isTrue,
        reason: 'the cut must not end mid-command',
      );
    });

    test('more than three images is a slideshow, not a question', () async {
      var calls = 0;
      final e = await AttachmentOcr.read(
        [
          for (var i = 0; i < 5; i++)
            ChatImage(name: 's$i.png', path: '/tmp/s$i.png'),
        ],
        readBase64: (_) async => 'aGk=',
        ocr: (_) async {
          calls++;
          return 'text';
        },
      );
      expect(calls, AttachmentOcr.maxImages);
      expect(e.any, isTrue);
    });
  });

  group('AutopilotService.ocrImageBase64', () {
    test('posts the image to /ocr and returns the text', () async {
      String? sentPath;
      String? sentBody;
      final svc = AutopilotService(
        c: MockClient((request) async {
          sentPath = request.url.path;
          sentBody = request.body;
          return http.Response(
            jsonEncode({'ok': true, 'text': 'FastEthernet0/1 down'}),
            200,
          );
        }),
      );
      final text = await svc.ocrImageBase64('aGk=');
      expect(text, 'FastEthernet0/1 down');
      expect(sentPath, '/ocr');
      expect(jsonDecode(sentBody!), {'image': 'aGk='});
    });

    test('a sidecar refusal is a readable exception', () async {
      final svc = AutopilotService(
        c: MockClient(
          (_) async => http.Response(
            jsonEncode({'ok': false, 'error': 'tesseract is not installed'}),
            503,
          ),
        ),
      );
      await expectLater(
        svc.ocrImageBase64('aGk='),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('tesseract is not installed'),
          ),
        ),
      );
    });
  });
}
