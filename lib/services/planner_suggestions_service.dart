import '../models/network_intent.dart';
import 'validator_service.dart';

/// Turns a plan's own validator issues, assumptions and open questions into
/// short, concrete, user-facing suggestions.
///
/// This is the offline answer to "the brief was faulty - what do I do?".
/// It is pure and deterministic: the same intent always yields the same
/// suggestions, with no model and no network involved. It never invents
/// credentials - when a control needs a value the brief did not supply, it
/// asks the user for it instead of guessing one.
class PlannerSuggestionsService {
  const PlannerSuggestionsService._();

  static List<String> forIntent(
    NetworkIntent intent, {
    String target = 'gns3',
  }) {
    final out = <String>[];
    void add(String s) {
      final t = s.trim();
      if (t.isEmpty || out.contains(t)) return;
      out.add(t);
    }

    // 1. A plan with nothing in it: the single most useful thing to say.
    if (intent.nodes.isEmpty) {
      add('No devices were recognised. Name what you want built, for '
          'example "2 routers, 1 switch, 1 server and 4 PCs with OSPF".');
      add('Keep device counts as digits, and use plain device words '
          '(router, switch, pc, server, access point). The local planner is '
          'bilingual English/Arabic, so either is fine.');
      return out;
    }

    // 2. The validator already writes the precise, actionable message for
    //    every structural fault, so reuse it rather than inventing a second
    //    set of rules that could disagree with it.
    for (final issue in ValidatorService.validate(intent, target: target)) {
      final suffix = issue.severity == 'error'
          ? 'Fix this before executing.'
          : 'Review before executing.';
      add('${issue.message} $suffix');
    }

    // 3. Credentials are never invented, so a control that needs one is
    //    always worth an explicit ask.
    final s = intent.security;
    if (s.aaa && (s.aaaUsername == null || s.aaaPassword == null)) {
      add('AAA is on but no username/password was given. Add "username '
          'labadmin password <your password>", or the VTY login is left to '
          'the default, which is unsafe.');
    }
    if (s.ipsecVpn && (s.vpnPreSharedKey ?? '').isEmpty) {
      add('The site-to-site VPN needs a pre-shared key. Add "pre-shared key '
          '<your key>" and the crypto map will be generated for you.');
    }

    // 4. A server that was placed but never given a role.
    for (final n in intent.nodes.where((n) => n.type == 'server')) {
      if (n.services.isEmpty) {
        add('${n.name} has no service role. Say what it serves - one of '
            'DHCP, DNS, HTTP, FTP, email, AAA, NTP, TFTP or syslog.');
      }
    }

    // 5. The planner's own remaining questions, phrased as things to answer.
    for (final q in intent.questions) {
      final t = q.trim();
      if (t.isEmpty) continue;
      add(t.endsWith('?') || t.endsWith('.') ? t : '$t?');
    }

    return out;
  }

  /// A multi-line block for logs and chat replies, or a short all-clear.
  static String summaryLine(NetworkIntent intent, {String target = 'gns3'}) {
    final items = forIntent(intent, target: target);
    if (items.isEmpty) return 'No suggested fixes - the plan is complete.';
    return 'Suggested fixes (${items.length}):\n'
        '${items.map((e) => '- $e').join('\n')}';
  }
}
