import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/app/destinations.dart';
import 'package:net_builder/services/capability_registry.dart';

void main() {
  final all = CapabilityRegistry.all;

  test('the registry is not empty and every entry has a real button', () {
    expect(all.length, greaterThan(30));
    for (final action in all) {
      expect(action.id.trim(), isNotEmpty, reason: 'an action needs an id');
      expect(action.label.trim(), isNotEmpty, reason: '${action.id} has no label');
      expect(
        action.description.trim(),
        isNotEmpty,
        reason: '${action.id} has no description - a button nobody can '
            'understand is not a feature',
      );
      expect(
        CapabilityRegistry.groupOrder,
        contains(action.group),
        reason: '${action.id} is in a group the hub does not render',
      );
    }
  });

  test('ids are unique, so two features can never be confused', () {
    final ids = <String>{};
    for (final action in all) {
      expect(ids.add(action.id), isTrue, reason: 'duplicate id ${action.id}');
    }
  });

  test('every screen in the app is reachable from a button', () {
    for (final destination in AppDestination.values) {
      expect(
        CapabilityRegistry.reaches(destination),
        isTrue,
        reason: '${destination.title} has no button anywhere in the registry - '
            'this is the bug this registry exists to prevent',
      );
    }
  });

  test('every group in the order has at least one action in it', () {
    for (final group in CapabilityRegistry.groupOrder) {
      expect(
        CapabilityRegistry.inGroup(group),
        isNotEmpty,
        reason: 'group "$group" renders as an empty heading',
      );
    }
  });

  test('search matches on words, and on all of them', () {
    expect(
      CapabilityRegistry.search('subnet').any((a) => a.id == 'tools.subnet'),
      isTrue,
    );
    // "pkt fix" must not match something that only says "fix".
    final both = CapabilityRegistry.search('pkt generate');
    expect(both.map((a) => a.id), contains('pt.generate'));
    expect(
      both.every(
        (a) => '${a.label} ${a.description} ${a.keywords.join(' ')}'
            .toLowerCase()
            .contains('pkt'),
      ),
      isTrue,
    );
    expect(CapabilityRegistry.search('').length, all.length);
    expect(CapabilityRegistry.search('zzzz-nothing').isEmpty, isTrue);
  });

  test('the terraform export exists, and says it is Terraform', () {
    final terraform = all.firstWhere((a) => a.id == 'export.terraform');
    expect(terraform.label.toLowerCase(), contains('terraform'));
    expect(terraform.keywords, contains('iac'));
  });

  test('actions that write to devices are marked as such', () {
    final marked = [
      'pt.generate',
      'pt.saveVerified',
      'pt.open',
      'pt.gns3',
      'pt.run.stop',
      'pt.run.pause',
    ];
    for (final id in marked) {
      final action = all.firstWhere((a) => a.id == id);
      expect(
        action.touchesDevices,
        isTrue,
        reason: '$id changes something outside the app and must say so',
      );
    }
  });

  test('actions that need a plan are exactly the ones that use one', () {
    // The plan-dependent entries all read `intent`, so they must be gated:
    // a hub button that throws on tap is worse than a disabled one.
    for (final id in const [
      'plan.validate',
      'plan.suggestions',
      'plan.execute',
      'tools.duplicates',
      'tools.overlaps',
      'pt.generate',
      'pt.gns3',
      'export.cisco',
      'export.terraform',
    ]) {
      final action = all.firstWhere((a) => a.id == id);
      expect(action.needsPlan, isTrue, reason: '$id reads the open plan');
    }
  });

  test('the network operations the app used to hide are all present', () {
    for (final id in const [
      'tools.subnet',
      'tools.vlsm',
      'tools.summarize',
      'tools.addressing',
      'tools.acl',
      'tools.diagnostics',
      'tools.local',
      'export.terraform',
      'analyze.pkt',
      'memory.export',
      'system.sidecar',
    ]) {
      expect(
        all.any((a) => a.id == id),
        isTrue,
        reason: '$id was a feature with no way in before this registry',
      );
    }
  });
}
