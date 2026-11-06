import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/conversation_titles.dart';

/// Enterprise briefs name their network ("Build the enterprise network for
/// company Contoso"), and the conversation is titled for the same words.
/// The old title read the first troubleshooting topic, so ten enterprise
/// labs all arrived in the sidebar as "Firewall Troubleshooting" - and the
/// only way to tell them apart was opening each one.
void main() {
  test('a brief naming the company titles from that name', () {
    expect(
      ConversationTitles.generate(
        'Build the enterprise network for company Contoso. HQ: 2 firewalls '
        '(ASA 5506-X) at the internet edge, 2 core routers running OSPF.',
      ),
      'Contoso',
    );
  });

  test('"named X" and "lab named X" titles from the name', () {
    expect(
      ConversationTitles.generate(
        'Design a campus network named campus-core. 3 routers running OSPF.',
      ),
      'Campus-core',
    );
    expect(
      ConversationTitles.generate('Create a lab named acme-branch.'),
      'Acme-branch',
    );
  });

  test('briefs without a name keep the old topic/device titles', () {
    expect(
      ConversationTitles.generate(
        'Why can PC1 not reach the server? VLAN 10 issue with OSPF',
      ),
      contains('VLAN'),
    );
    expect(
      ConversationTitles.generate('2 routers and 4 switches'),
      '2 routers and 4 switches',
    );
  });
}
