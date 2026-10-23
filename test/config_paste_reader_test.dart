import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/config_paste_reader.dart';

/// A pasted `show run` is neither a question nor a build brief: the reader
/// has to recognize it before the planner turns "22 interfaces" into 22
/// devices.
void main() {
  const headered = '''
Building configuration...

Current configuration : 980 bytes
!
version 15.1
hostname R1
!
interface GigabitEthernet0/0
 ip address 10.0.0.1 255.255.255.252
 no shutdown
!
line vty 0 4
 transport input ssh
!
end
''';

  const headerless = '''
hostname SW1
interface FastEthernet0/1
 switchport mode access
 switchport access vlan 10
interface FastEthernet0/2
 switchport mode trunk
spanning-tree mode rapid-pvst
''';

  test('a real show-run paste is recognized', () {
    expect(ConfigPasteReader.matches(headered), isTrue);
  });

  test('a headerless paste with several config lines is recognized', () {
    expect(ConfigPasteReader.matches(headerless), isTrue);
  });

  test('a single-line message never matches', () {
    expect(ConfigPasteReader.matches('hostname R1'), isFalse);
    expect(ConfigPasteReader.matches('interface g0/0'), isFalse);
  });

  test('a multi-line plan brief is not a config paste', () {
    expect(
      ConfigPasteReader.matches(
        '2 routers and 4 switches\nwith OSPF\nand a server',
      ),
      isFalse,
    );
  });

  test('multi-line prose about networks is not a config paste', () {
    expect(
      ConfigPasteReader.matches(
        'The interface went down yesterday.\n'
        'We think it is the cable.\n'
        'Can you help us check the switch?',
      ),
      isFalse,
    );
  });

  test('the hostname is extracted when present', () {
    expect(ConfigPasteReader.deviceName(headered), 'R1');
    expect(ConfigPasteReader.deviceName('no hostname here\nat all'), isNull);
  });
}
