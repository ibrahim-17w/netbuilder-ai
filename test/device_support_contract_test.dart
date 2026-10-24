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

  test('a hub is fully supported: offline build AND live placement', () {
    const intent = NetworkIntent(
      projectName: 'contract',
      nodes: [NetNode(name: 'H1', type: 'hub')],
    );
    final issues = ValidatorService.validate(intent, target: 'packet-tracer');

    // The hub graduated: a taught palette path places it live, so it is a
    // plain supported device - no device-kind error and no offline-only
    // note. (A lone node with no links is still an island error - the
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
    expect(message, isNot(contains('offline .pkt')));
    expect(supportedDeviceKinds.contains('hub'), isTrue);
  });

  test(
    'a bare controller is recognized and fully supported, not ignored',
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
      expect(message, isNot(contains('offline .pkt')));
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
