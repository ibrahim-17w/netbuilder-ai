import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/offline_assistant_service.dart';

/// The offline battery: every line here is a question the app must answer
/// with NO model and NO API key. Nothing in this file ever sets a key, so a
/// pass is proof the answer came from the offline knowledge table.
///
/// `test/offline_intelligence_test.dart` is the measurement harness for the
/// "answers everything offline" claim: adding a knowledge topic means adding
/// its line here.
void main() {
  AssistantReply ask(String q) => OfflineAssistantService.reply(
    rawText: q,
    normalized: q.toLowerCase(),
    target: 'packet-tracer',
  );

  void answers(String q, String expected) {
    test('offline: "$q"', () {
      final r = ask(q);
      expect(r.intent, isNot('offtopic'), reason: 'must not be declined');
      expect(r.text.toLowerCase(), contains(expected.toLowerCase()));
      expect(
        r.text.toLowerCase(),
        isNot(contains('unavailable')),
        reason: 'no model is needed for this',
      );
    });
  }

  group('computed answers are actually computed', () {
    test('subnet facts for 192.168.10.5/26', () {
      final r = ask('what is the broadcast address of 192.168.10.5/26');
      expect(r.text, contains('192.168.10.63'));
      expect(r.text, contains('192.168.10.0'));
      expect(r.text, contains('62'));
      expect(r.text, contains('255.255.255.192'));
    });

    test('hosts in a /28', () {
      final r = ask('how many hosts does a /28 subnet support');
      expect(r.text, contains('14'));
      expect(r.text, contains('255.255.255.240'));
    });

    test('wildcard for /27', () {
      final r = ask('what is the wildcard mask for /27');
      expect(r.text, contains('0.0.0.31'));
    });

    test('wildcard from a dotted mask', () {
      final r = ask('wildcard mask for 255.255.255.224');
      expect(r.text, contains('0.0.0.31'));
    });

    test('summarize two /25s', () {
      final r = ask('summarize 10.10.0.0/25 and 10.10.0.128/25');
      expect(r.text, contains('10.10.0.0/24'));
    });

    test('reverse dns name', () {
      final r = ask('reverse dns for 192.168.1.10');
      expect(r.text, contains('10.1.168.192.in-addr.arpa'));
    });
  });

  group('the corpus answers with no key', () {
    answers('how do I configure ssh on a switch', 'transport input ssh');
    answers('configure ssh step by step', 'crypto key generate rsa');
    answers('how do I enable port security on a switch', 'port-security');
    answers('how does dhcp snooping work', 'trust');
    answers('how do I configure hsrp', 'standby');
    answers('static route syntax', 'ip route');
    answers('how do I save the config', 'startup-config');
    answers('which command shows interfaces', 'show ip interface brief');
    answers('the link is red in packet tracer', 'crossover');
    answers('explain dtp and switchport modes', 'nonegotiate');
    answers('what is a mac address-table', 'show mac');
    answers('how to secure wifi with wpa2', 'WPA2-Personal');
    answers('what does a wireless controller do', 'SSID');
    answers('how do I verify ospf neighbors', 'FULL');
    answers('ospf stuck in exstart', 'MTU');
    answers('cannot ping the gateway', 'gateway');
    answers('how do I set a password on the router', 'enable secret');
    answers('how to change the hostname', 'hostname');
    answers('how do I make the core switch the root bridge', 'root primary');
    answers('dhcp relay across vlans', 'ip helper-address');
    answers('how do I configure a trunk port on a 2960 switch', 'trunk');
    answers('what is a loopback used for', 'router-id');
    answers('explain vlsm', 'VLSM');
    answers('how does route summarization work', 'summarization');
    answers('what cable do I use between two switches', 'crossover');
    answers('do I need a clock rate on the dce side', 'clock rate');
    answers('which cable to connect pc to switch', 'straight');
    answers('the pc cannot reach 8.8.8.8', 'NAT');
    answers('how do I check my ip address', 'ipconfig');
    answers('how do I find the mac address of a pc', 'mac');
    answers('request timed out when pinging across routers', 'route');
    answers('what is a default gateway', 'gateway');
    answers('how do I add a device in packet tracer', 'Connections');
    answers('i am new to packet tracer', 'crossover');
    answers('how do I connect two devices', 'cable');
    answers("laptop won't join the wifi", 'SSID');
    answers('what is duplex mismatch', 'late collision');
    answers('show commands to verify a lab', 'show ip route');
    answers('how do I test connectivity from a pc', 'ping');
    answers('the pc has 169.254 address', 'DHCP');
    answers('how do I rename the switch', 'hostname');
    answers('what does dce mean on a serial link', 'DCE');
    answers('how many addresses does a /30 have', '2');
  });

  group('the advisor answers design questions with no key', () {
    answers('what router should i use in this case', 'what i would do');
    answers('which router should i get for a home', 'all-in-one');
    answers('how many access points do i need for 50 users', 'access point');
    answers(
      'which is better, fiber or copper for a run between buildings',
      'fiber',
    );
    answers('is a managed switch worth it', 'managed');
    answers('do i need a poe switch for 6 cameras', 'nvr');
    answers('my wifi is slow in the back office, what should i do', 'wired');
    answers('review my design for a small office', 'what i would do');
    answers('how much bandwidth do i need for 50 users', 'mbit/s');
  });

  group('the boundary still holds', () {
    test('off-topic stays declined', () {
      expect(ask("what's the weather today").intent, 'offtopic');
      expect(ask('write me a python script to parse a csv').intent, 'offtopic');
    });

    test('a build request is planning, not a knowledge answer', () {
      final r = ask('2 routers and a switch for the lab');
      expect(r.intent, isNot('howto'));
    });

    test('a device-counted question is left to the planner', () {
      // Counts mean build: the knowledge table must not swallow it.
      final r = ask('build 3 routers with ospf');
      expect(r.intent, isNot('howto'));
    });
  });
}
