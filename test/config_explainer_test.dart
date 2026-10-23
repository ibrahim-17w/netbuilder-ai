import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/config_explainer.dart';

/// The review must say something true about a real config - sections that
/// are there, findings with reasons - and stay silent about what is absent.
void main() {
  const weak = '''
hostname R1
interface GigabitEthernet0/0
 ip address 10.0.0.1 255.255.255.0
 no shutdown
interface FastEthernet0/1
 switchport access vlan 1
line vty 0 4
 password letmein
 login
 transport input telnet
enable password cisco123
username admin password admin123
ip http server
''';

  const hardened = r'''
hostname R2
service password-encryption
enable secret 5 $1$SALT$hashedvaluehere
username admin secret 5 $1$SALT$anotherhash
interface GigabitEthernet0/0
 ip address 10.0.0.2 255.255.255.0
 no shutdown
line vty 0 4
 login local
 transport input ssh
ip route 0.0.0.0 0.0.0.0 10.0.0.1
''';

  test('the review names the device and its sections', () {
    final r = ConfigExplainer.explain(hardened);
    expect(r.device, 'R2');
    final text = r.toMarkdown();
    expect(text, startsWith('**Config review - R2**'));
    expect(text, contains('Hostname'));
    expect(text, contains('Interfaces'));
    expect(text, contains('Static routes'));
    expect(text, contains('Lines (vty/console)'));
  });

  test('a weak config earns its findings, each with its reason', () {
    final r = ConfigExplainer.explain(weak);
    final warnings = r.findings
        .where((f) => f.severity == 'warning')
        .map((f) => f.message)
        .toList();
    expect(warnings.length, greaterThanOrEqualTo(4));
    expect(
      warnings.any((m) => m.contains('telnet')),
      isTrue,
      reason: 'cleartext transport must be called out',
    );
    expect(warnings.any((m) => m.contains('enable secret')), isTrue);
    expect(
      warnings.any((m) => m.contains('service password-encryption')),
      isTrue,
      reason: 'plaintext passwords without the scrambling command',
    );
    expect(warnings.any((m) => m.contains('VLAN 1')), isTrue);
  });

  test('a hardened config produces no warnings', () {
    final r = ConfigExplainer.explain(hardened);
    expect(r.findings.where((f) => f.severity == 'warning'), isEmpty);
    expect(r.toMarkdown(), contains('No classic-mistake findings'));
  });

  test('a vty finding never reads a password from the console block', () {
    // The console carries the shared password; vty is clean. A finding about
    // vty passwords here would mean the block reader overran its section.
    const config = '''
hostname R3
line con 0
 password consolepass
 login
line vty 0 4
 login local
 transport input ssh
''';
    final r = ConfigExplainer.explain(config);
    expect(
      r.findings.where((f) => f.severity == 'warning'),
      isEmpty,
      reason:
          'the console block is a finding this version chooses not to '
          'make; vty itself is clean',
    );
  });

  test('an empty paste is safe', () {
    final r = ConfigExplainer.explain('');
    expect(r.sections, isEmpty);
    expect(r.findings, isEmpty);
    expect(r.toMarkdown(), contains('Config review'));
  });
}
