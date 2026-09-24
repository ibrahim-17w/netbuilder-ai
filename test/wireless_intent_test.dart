import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/models/network_intent.dart';

void main() {
  test('SSID + WEP phrase lands on the AP serviceRules', () {
    final intent = NetworkIntent.parseSimple(
      'wifi-lab',
      'one access point AP1, 2 laptops. AP1 SSID CORP with WEP key 1234567890',
    );
    final ap = intent.nodes.firstWhere(
      (n) => n.type == 'wireless' || n.type == 'ap',
    );
    final wl = ap.serviceRules['wireless'] as Map<String, dynamic>;
    expect(wl['ssid'], 'CORP');
    expect(wl['wep'], '1234567890');
  });

  test('WPA2 request is captured as a flag', () {
    final intent = NetworkIntent.parseSimple(
      'wpa-lab',
      'an access point AP1 with SSID OfficeNet using WPA2',
    );
    final ap = intent.nodes.firstWhere(
      (n) => n.type == 'wireless' || n.type == 'ap',
    );
    final wl = ap.serviceRules['wireless'] as Map<String, dynamic>;
    expect(wl['ssid'], 'OfficeNet');
    expect(wl['wpa2'], true);
  });

  test('hidden ssid disables broadcast', () {
    final intent = NetworkIntent.parseSimple(
      'hidden-lab',
      'an access point AP1 with hidden SSID SECRETNET',
    );
    final ap = intent.nodes.firstWhere(
      (n) => n.type == 'wireless' || n.type == 'ap',
    );
    final wl = ap.serviceRules['wireless'] as Map<String, dynamic>;
    expect(wl['ssid'], 'SECRETNET');
    expect(wl['broadcast'], false);
  });
}
