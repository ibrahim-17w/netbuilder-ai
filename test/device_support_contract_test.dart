import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/nlu/lexicon.dart';
import 'package:net_builder/services/validator_service.dart';

void main() {
  test('the unsupported set partitions the parsed vocabulary', () {
    final known = {for (final kind in deviceKinds) kind.type};
    expect(unsupportedDeviceKinds, isNotEmpty);
    expect(known.containsAll(unsupportedDeviceKinds), isTrue);
    expect(supportedDeviceKinds.intersection(unsupportedDeviceKinds), isEmpty);
    expect(supportedDeviceKinds.union(unsupportedDeviceKinds), known);
  });

  test('a hub is offline-buildable, not silently rejected', () {
    const intent = NetworkIntent(
      projectName: 'contract',
      nodes: [NetNode(name: 'H1', type: 'hub')],
    );
    final issues = ValidatorService.validate(intent, target: 'packet-tracer');

    // The offline .pkt is the primary build path, so a hub is no longer a
    // device-kind error: it compiles from a real Packet Tracer template. The
    // finding is the honest note that only the LIVE executor cannot place it
    // yet. (A lone node with no links is still an island error - the
    // topology's business, not the device gate's.)
    expect(
      issues.where(
        (issue) =>
            issue.severity == 'error' && issue.message.contains('device type'),
      ),
      isEmpty,
      reason: issues.map((issue) => issue.message).join('\n'),
    );
    final message = issues.map((issue) => issue.message).join('\n');
    expect(message, contains('H1 will be in the offline .pkt'));
    expect(message, contains('does not place it yet'));
  });

  test(
    'a bare controller is recognized and offline-buildable, not ignored',
    () {
      final built = NetworkIntent.parseSimple(
        'contract',
        CasualEnglish.normalize('1 controller'),
      );
      expect(
        built.nodes.where((node) => node.type == 'controller'),
        hasLength(1),
      );
      final message = ValidatorService.validate(
        built,
        target: 'packet-tracer',
      ).map((issue) => issue.message).join('\n');
      expect(
        message,
        isNot(contains('controller device type is not supported')),
      );
      expect(message, contains('CTRL1 will be in the offline .pkt'));
    },
  );

  test('a supported device does not trip the unsupported gate', () {
    const intent = NetworkIntent(
      projectName: 'contract',
      nodes: [
        NetNode(name: 'R1', type: 'router'),
        NetNode(name: 'PC1', type: 'pc'),
      ],
    );
    final issues = ValidatorService.validate(intent, target: 'packet-tracer');
    expect(
      issues.any(
        (issue) =>
            issue.severity == 'error' &&
            issue.message.contains('not supported'),
      ),
      isFalse,
    );
  });
}
