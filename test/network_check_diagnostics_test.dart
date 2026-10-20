import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/network_check_diagnostics.dart';

void main() {
  test('failed DNS checks get record and client hypotheses', () {
    final causes = NetworkCheckDiagnostics.likelyCauses({
      'kind': 'service',
      'detail': 'DNS lookup failed for app.example',
    });

    expect(causes, contains(contains('DNS server address')));
    expect(causes, contains(contains('DNS service is enabled')));
    expect(causes, contains(contains('ping alone does not prove')));
  });

  test('failed trunk checks mention mode, VLANs, and forwarding evidence', () {
    final context = NetworkCheckDiagnostics.promptContext({
      'kind': 'vlan_trunk',
      'detail': 'VLAN 30 missing',
    });

    expect(context, contains('trunk mode'));
    expect(context, contains('allowed VLANs'));
    expect(context, contains('live trunk is forwarding'));
  });

  test('unclassified checks stay evidence-led and do not prescribe edits', () {
    final causes = NetworkCheckDiagnostics.likelyCauses({
      'kind': 'unknown',
      'detail': 'check 42 failed',
    });

    expect(causes.last, contains('targeted live check'));
    expect(causes.join(' '), isNot(contains('change the configuration')));
  });
}
