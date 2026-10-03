import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/offline_assistant_service.dart';

void main() {
  test('preview advice replies', () {
    final lab = NetworkIntent.parseSimple(
      'p',
      '2 routers, 1 switch and 4 pcs with ospf',
    );
    final prompts = <(String, NetworkIntent?)>[
      ('what router should I use in this case?', lab),
      ('which router should I get for an office with 20 employees?', null),
      ('how many access points do i need for 40 users?', null),
      ('is a managed switch worth it for an office?', null),
      ('my wifi is slow in the back office, what should i do?', null),
      ('should the point of sale be on its own vlan?', null),
      ('review my design for a small office', null),
      ('which model should i use for an ospf lab in packet tracer?', lab),
      ('what do you recommend for a small office network?', null),
      ('do i need a poe switch for 6 cameras?', null),
      ('is wifi 7 worth it over wifi 6?', null),
      ('what should i use for remote access to the office?', null),
    ];
    for (final (q, plan) in prompts) {
      final r = OfflineAssistantService.reply(
        rawText: q,
        normalized: q.toLowerCase(),
        target: 'packet-tracer',
        plan: plan,
      );
      // ignore: avoid_print
      print('\n===== "$q"  [${r.intent}] =====');
      // ignore: avoid_print
      print(r.text);
      // ignore: avoid_print
      print('--- chips: ${r.quickReplies} | questions: ${r.questions}');
    }
  });
}
