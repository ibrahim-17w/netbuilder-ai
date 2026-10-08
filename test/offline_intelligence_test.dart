import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
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

  group('the thin concept answers carry real walkthroughs', () {
    test('PAT overload gets the NAT walkthrough', () {
      final r = ask('how do I configure PAT overload');
      expect(r.text.toLowerCase(), contains('overload'));
      expect(r.text.toLowerCase(), contains('ip nat inside source list'));
      expect(r.text.toLowerCase(), contains('ip nat inside'));
      expect(r.text.toLowerCase(), contains('ip nat outside'));
      expect(r.text.toLowerCase(), contains('show ip nat translations'));
    });

    test('EIGRP gets a config walkthrough with wildcard masks', () {
      final r = ask('how does EIGRP work');
      expect(r.text.toLowerCase(), contains('router eigrp 100'));
      expect(r.text.toLowerCase(), contains('0.0.0.255'));
      expect(r.text.toLowerCase(), contains('passive-interface'));
      expect(r.text.toLowerCase(), contains('show ip eigrp neighbors'));
    });

    test('BGP gets a basic eBGP walkthrough', () {
      final r = ask('how does BGP work');
      expect(r.text, contains('router bgp 65001'));
      expect(r.text, contains('neighbor 10.0.0.2 remote-as 65002'));
      expect(r.text, contains('network 192.168.1.0 mask 255.255.255.0'));
      expect(r.text, contains('show ip bgp summary'));
    });

    test('RSTP no longer lands in the classic STP answer', () {
      // 'rstp' contains 'stp' as a substring; the concept trigger must be
      // whole-word so rapid spanning tree routes onward from the concept
      // layer instead of getting the classic STP explainer.
      final r = ask('how do I configure RSTP');
      expect(r.text.toLowerCase(), isNot(contains('blocking redundant ports')));
    });

    test('plain STP still gets the spanning-tree answer', () {
      final r = ask('how does STP work');
      expect(r.text.toLowerCase(), contains('blocking redundant ports'));
    });

    test('DHCPv6 does not land in the DHCPv4 answer', () {
      final r = ask('how do I configure DHCPv6');
      expect(r.text.toLowerCase(), isNot(contains('handing out addresses')));
    });

    test('plain DHCP keeps its answer', () {
      final r = ask('how does DHCP work');
      expect(r.text.toLowerCase(), contains('handing out addresses'));
    });
  });

  group('a question outside the material gets a guided near-miss', () {
    test('something unrelated says so plainly and offers no chips', () {
      final r = ask('how do I set up an email marketing campaign');
      expect(r.intent, 'missing');
      expect(r.text.toLowerCase(), contains('not in my offline material'));
      expect(r.quickReplies, isEmpty,
          reason: 'nothing nearby, so nothing is offered');
    });

    test('a near question is pointed at ground the offline path covers', () {
      // Uncovered by the knowledge table, but its words sit right next to
      // topics the offline path answers - the reply should say so and hand
      // over real questions as quick replies.
      final r = ask('how do I see the neighbors of a switch');
      expect(r.intent, 'missing');
      expect(r.text.toLowerCase(), contains('not in my offline material'));
      expect(r.text.toLowerCase(), contains('nearby'));
      expect(r.quickReplies, isNotEmpty);
      expect(r.quickReplies.length, lessThanOrEqualTo(4));
      expect(r.quickReplies, contains('how do I verify OSPF neighbors'));
    });

    test('covered questions never reach the missing reply', () {
      expect(ask('how do I configure SSH on a switch').intent, 'howto');
      expect(ask('how many hosts does a /28 subnet support').intent, 'howto');
    });
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

  group('corpus entries route end to end through the service', () {
    // The concept chain runs before the knowledge table, so an entry whose
    // trigger word is a substring of a concept key (rstp in stp, dhcpv6 in
    // dhcp) only reaches the corpus when the concept triggers exclude it.
    // These pin that seam: the answer must be the corpus entry, not the
    // generic concept.
    test('rstp reaches the corpus, not the stp concept', () {
      final r = ask('how do I configure rstp on a switch');
      expect(r.text.toLowerCase(), contains('rapid-pvst'));
      expect(r.text.toLowerCase(), contains('portfast'));
    });

    test('rstp is not answered by the generic stp explainer', () {
      final stp = ask('what is stp');
      final rstp = ask('how do I enable rstp');
      expect(stp.text, isNot(equals(rstp.text)));
    });

    test('dhcpv6 reaches the corpus, not the dhcp concept', () {
      final r = ask('what is stateless dhcpv6');
      expect(r.text.toLowerCase(), contains('ipv6 nd other-config-flag'));
    });

    test('dhcp for ipv6 reaches the corpus too', () {
      final r = ask('how do I set up dhcp for ipv6');
      expect(r.text.toLowerCase(), contains('ipv6 dhcp'));
    });
  });

  group('full protocol names route through the concept chain', () {
    // The concept reader canonicalizes its input, so a full name must land
    // on the same explainer its acronym does - and a fault paraphrase with
    // no concept hook must still fall through to the corpus entry.
    test('border gateway protocol reaches the bgp explainer', () {
      final r = ask('how does the border gateway protocol work');
      expect(r.text.toLowerCase(), contains('router bgp'));
    });

    test('network address translation reaches the NAT walkthrough', () {
      final r = ask('what is network address translation');
      expect(r.text.toLowerCase(), contains('overload'));
    });

    test('access control lists reach the acl explainer', () {
      final r = ask('how do access control lists work');
      expect(r.text.toLowerCase(), contains('deny any'));
    });

    test('a fault paraphrase falls through to the corpus ladder', () {
      final r = ask('my pc does not get an ip address');
      expect(r.text.toLowerCase(), contains('169.254'));
    });
  });

  group('troubleshooting flows run inside the assistant', () {
    test('a symptom opens the interactive ladder, not a static answer', () {
      final r = ask('my pc cannot ping anything');
      expect(r.intent, 'troubleshoot');
      expect(r.flowState, isNotNull);
      expect(r.flowState, isNotEmpty);
      expect(r.text.toLowerCase(), contains('show ip interface brief'));
      expect(r.quickReplies, isNotEmpty);
    });

    test('an active flow advances and finishes with a fix', () {
      final start = ask('troubleshoot my connection');
      expect(start.intent, 'troubleshoot');
      final second = OfflineAssistantService.reply(
        rawText: 'down/down',
        normalized: 'down/down',
        target: 'packet-tracer',
        activeFlow: start.flowState,
      );
      expect(second.intent, 'troubleshoot');
      expect(second.text.toLowerCase(), contains('down/down'));
      expect(second.text.toLowerCase(), contains('layer 1'));
      expect(second.flowState, isEmpty, reason: 'a finished flow clears');
    });

    test('an explicit exit drops the ladder', () {
      final start = ask('troubleshoot my connection');
      final exit = OfflineAssistantService.reply(
        rawText: 'never mind',
        normalized: 'never mind',
        target: 'packet-tracer',
        activeFlow: start.flowState,
      );
      expect(exit.flowState, isEmpty);
    });
  });

  group('reachability is reasoned over the plan, not matched', () {
    test('why cannot pc1 ping pc2 walks the topology', () {
      final plan = NetworkIntent.parseSimple(
        'reach-chat',
        '2 routers, 2 switches and 4 PCs with OSPF',
      );
      final r = OfflineAssistantService.reply(
        rawText: "why can't PC1 ping PC3",
        normalized: "why can't pc1 ping pc3",
        target: 'packet-tracer',
        plan: plan,
      );
      expect(r.intent, 'reachability');
      // The answer is a ladder: link, addressing, and a routing note for
      // the cross-subnet walk - not a generic ping explanation.
      expect(r.text.toLowerCase(), contains('link'));
      expect(r.text.toLowerCase(), contains('addressing'));
      expect(r.quickReplies, isNotEmpty);
    });

    test('without a plan the question falls back to the generic ladder', () {
      final r = ask("why can't PC1 ping PC2");
      expect(r.intent, isNot('reachability'));
    });
  });

  group('plan-aware config answers', () {
    NetworkIntent lab() => NetworkIntent.parseSimple(
      'ground-chat',
      '2 routers, 2 switches and 4 PCs with OSPF',
    );

    test('a bare ospf question with a plan gets lab-specific commands', () {
      final r = OfflineAssistantService.reply(
        rawText: 'how do I configure ospf',
        normalized: 'how do i configure ospf',
        target: 'packet-tracer',
        plan: lab(),
      );
      expect(r.intent, 'howto');
      expect(r.text, contains('Your lab:'));
      expect(r.text, contains('router ospf 1'));
      expect(r.text, contains('network 10.0.0.0 0.0.0.3 area 0'));
      // The generic tail is replaced: the lab is known.
      expect(r.text.toLowerCase(), isNot(contains('if you tell me the lab')));
    });

    test('a concept question is grounded after the generic answer', () {
      final r = OfflineAssistantService.reply(
        rawText: 'what is a vlan',
        normalized: 'what is a vlan',
        target: 'packet-tracer',
        plan: lab(),
      );
      expect(r.intent, 'howto');
      expect(r.text.toLowerCase(), contains('your lab:'));
    });

    test('an ssh question grounds the knowledge-path answer', () {
      final r = OfflineAssistantService.reply(
        rawText: 'how do I configure ssh',
        normalized: 'how do i configure ssh',
        target: 'packet-tracer',
        plan: lab(),
      );
      expect(r.intent, 'howto');
      expect(r.text, contains('Your lab:'));
      expect(r.text.toLowerCase(), contains('crypto key generate'));
    });

    test('the same question without a plan keeps the honest near-miss', () {
      final r = ask('how do I configure ospf');
      expect(r.intent, 'missing');
      expect(r.quickReplies, isNotEmpty, reason: 'near-miss chips guide on');
    });
  });
}
