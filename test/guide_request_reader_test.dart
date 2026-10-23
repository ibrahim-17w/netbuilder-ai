import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/guide_request_reader.dart';

void main() {
  group('GuideRequestReader', () {
    test('instruction asks are caught', () {
      const yes = [
        'how do I build this?',
        'how can I set it up',
        'how to configure the network',
        'give me the steps',
        'show me the build instructions',
        'walk me through it',
        'step by step please',
        'build guide',
        'configuration steps',
        'just the instructions',
        'build it without a pkt',
        'no pkt, just tell me how',
      ];
      for (final text in yes) {
        expect(GuideRequestReader.matches(text), isTrue, reason: text);
      }
    });

    test('a file build request is not a guide request', () {
      const no = [
        'build the .pkt',
        'compile the pkt',
        'generate the packet tracer file',
        'make the file',
        'build the lab file',
        'hello',
        'how many routers do I need?',
        'what is a firewall?',
      ];
      for (final text in no) {
        expect(GuideRequestReader.matches(text), isFalse, reason: text);
      }
    });

    test('multi-line text is never a one-line guide request', () {
      expect(
        GuideRequestReader.matches('give me the steps\nand build it'),
        isFalse,
      );
    });
  });
}
