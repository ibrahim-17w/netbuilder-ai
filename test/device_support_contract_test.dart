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

  test('a hub is rejected with the supported-device list', () {
    const intent = NetworkIntent(
      projectName: 'contract',
      nodes: [NetNode(name: 'H1', type: 'hub')],
    );
    final errors = ValidatorService.validate(
      intent,
      target: 'packet-tracer',
    ).where((issue) => issue.severity == 'error').toList();

    expect(errors, isNotEmpty);
    final message = errors.map((issue) => issue.message).join('\n');
    expect(message, contains('hub device type is not supported yet'));
    expect(message, contains('Supported types:'));
    expect(message, contains('router'));
    expect(message, contains('No substitute device was placed'));
  });

  test('a bare controller is recognized and rejected, not ignored', () {
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
    expect(message, contains('controller device type is not supported yet'));
  });

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
