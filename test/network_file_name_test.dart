import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/build_artifact_service.dart';

/// Build output names a person can read: derived from the project name or
/// the brief's own words, never a bare timestamp, and never clobbering a
/// name already written this session.
void main() {
  NetworkIntent plan({
    String projectName = 'net',
    String routing = 'ospf',
    int routers = 2,
    int switches = 1,
    int pcs = 4,
  }) {
    final intent = NetworkIntent.parseSimple(
      'name-test',
      '$routers routers, $switches switches and $pcs PCs with $routing',
    );
    return intent.copyWith(projectName: projectName);
  }

  test('the brief wins: chat projects are conversation keys, not names', () {
    // In chat builds the plan's projectName is the conversation key
    // ('chat') - the description is the name the user would recognise.
    final name = BuildArtifactService.networkFileName(
      plan: plan(projectName: 'chat'),
      brief: 'Build a small office with OSPF between two sites',
      taken: {},
    );
    expect(name, contains('small'));
    expect(name, contains('ospf'));
    expect(name.startsWith('chat'), isFalse);
  });

  test('a named project names the file when there is no brief', () {
    final name = BuildArtifactService.networkFileName(
      plan: plan(projectName: 'Headquarters LAN'),
      taken: {},
    );
    expect(name, 'headquarters-lan.pkt');
  });

  test('an unnamed lab is named from its brief', () {
    final name = BuildArtifactService.networkFileName(
      plan: plan(),
      brief: 'Build a small office with OSPF between two sites',
      taken: {},
    );
    expect(name, contains('small'));
    expect(name, contains('ospf'));
    expect(name, endsWith('.pkt'));
    expect(name.startsWith('netbuilder-'), isFalse);
  });

  test('a lab nobody described is named from its topology', () {
    final name = BuildArtifactService.networkFileName(
      plan: plan(routing: 'static'),
      taken: {},
    );
    expect(name, '2-routers-1-switches-4-pcs-static.pkt');
  });

  test('a taken name gets -2 instead of clobbering', () {
    final name = BuildArtifactService.networkFileName(
      plan: plan(projectName: 'office'),
      taken: {'office.pkt'},
    );
    expect(name, 'office-2.pkt');
    final third = BuildArtifactService.networkFileName(
      plan: plan(projectName: 'office'),
      taken: {'office.pkt', 'office-2.pkt'},
    );
    expect(third, 'office-3.pkt');
  });

  test('the generic parser fallback "net" never becomes the name', () {
    final name = BuildArtifactService.networkFileName(
      plan: plan(projectName: 'net', routing: ''),
      taken: {},
    );
    expect(name, isNot(contains('net.pkt')));
    expect(name, isNotEmpty);
  });
}
