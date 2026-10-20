import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/adapters/packet_tracer_adapter.dart';
import 'package:net_builder/services/packet_tracer/model_compatibility.dart';
import 'package:net_builder/services/validator_service.dart';

const nearLimitInventory = '''
Create a Packet Tracer lab named **Tri-Site Resilient Services Lab**.

**Inventory — exactly 48 devices**

- 3 Cisco 2911 routers: `R-HQ`, `R-EAST`, `R-WEST`
- 4 Catalyst 2960-24TT switches: `SW-HQ-DIST`, `SW-HQ-ACCESS`, `SW-EAST`, `SW-WEST`
- 24 `PC-PT` PCs: `PC-HQ-01`–`PC-HQ-08`, `PC-EAST-01`–`PC-EAST-08`, `PC-WEST-01`–`PC-WEST-08`
- 8 `Server-PT` servers: `SRV-01`–`SRV-08`
- 2 `AccessPoint-PT` access points: `AP-HQ`, `AP-EAST`
- 2 `Laptop-PT` laptops: `LT-HQ-01`, `LT-EAST-01`
- 5 `IP Phone-PT` phones: `IPPH-HQ-01`, `IPPH-EAST-01`, `IPPH-EAST-02`, `IPPH-WEST-01`, `IPPH-WEST-02`

That is **48 devices total**. Do not add cloud devices, printers, spare endpoints, or other equipment. First check that the builder supports each requested model. If any model is unsupported, list the exact model and ask me what compatible model to use. Do not silently substitute, remove, or add devices.

**Topology and cabling**

Connect each router’s `G0/0` to its site switch: HQ to `SW-HQ-DIST Gi0/1`, East to `SW-EAST Gi0/1`, and West to `SW-WEST Gi0/1`. Connect `SW-HQ-DIST Gi0/2` to `SW-HQ-ACCESS Gi0/1` as a trunk.

Create a redundant router triangle using these links:

- `R-HQ G0/1` to `R-EAST G0/1`
- `R-EAST G0/2` to `R-WEST G0/1`
- `R-WEST G0/2` to `R-HQ G0/2`

Use copper crossover for router-to-router links and copper straight-through for device-to-switch links. Configure trunking separately from the cable type. If the builder cannot make a specified connection, identify the exact endpoint and port; do not choose a different port silently.

Connect `SRV-01`–`SRV-08` to `SW-HQ-DIST Fa0/1`–`Fa0/8`. Connect `PC-HQ-01`–`PC-HQ-04` to `SW-HQ-DIST Fa0/9`–`Fa0/12`, and `PC-HQ-05`–`PC-HQ-08` to `SW-HQ-ACCESS Fa0/1`–`Fa0/4`. Connect East PCs to `SW-EAST Fa0/1`–`Fa0/8` and West PCs to `SW-WEST Fa0/1`–`Fa0/8`.

Connect the HQ phone to `SW-HQ-DIST Fa0/13` and `AP-HQ` to `Fa0/14`. Connect East phones to `SW-EAST Fa0/9`–`Fa0/10` and `AP-EAST` to `Fa0/11`. Connect West phones to `SW-WEST Fa0/9`–`Fa0/10`. Associate each laptop wirelessly with its site’s AP; do not cable the laptops.

**Network configuration**

Use VLAN 10 for users, VLAN 20 for voice, VLAN 30 for HQ servers, VLAN 40 for Wi-Fi, and VLAN 99 for management/native trunk traffic. Set phone switchports to user access VLAN 10 with voice VLAN 20. AP client traffic belongs to VLAN 40. Trunks should carry only the VLANs needed at that site.

Use router-on-a-stick at each site. The gateway is `.1` in each subnet:

- HQ: `10.10.<VLAN>.0/24`
- East: `10.20.<VLAN>.0/24`
- West: `10.30.<VLAN>.0/24`

Create only the relevant VLAN interfaces at each site; VLAN 30 is HQ-only. Use OSPF area 0 across the three-router triangle and advertise the site LANs. Use these `/30` WAN subnets: HQ–East `10.255.0.0/30`, East–West `10.255.0.4/30`, and West–HQ `10.255.0.8/30`.

Give servers static addresses `10.10.30.11`–`10.10.30.18`, with gateway `10.10.30.1`. Assign roles in order: DHCP, DNS, HTTP, Email, FTP, NTP, Syslog, and AAA. Configure DHCP relay and scopes for the user, voice, and Wi-Fi VLANs at all three sites. Add DNS records `intranet.lab` for the HTTP server and `mail.lab` for the Email server.

Enable SSH rather than Telnet, use VLAN 99 for network-device management, and configure the phones for voice VLAN 20. Configure both APs with SSID `LAB-STAFF`, WPA2-PSK key `LabWiFi!2026`, and Wi-Fi clients on VLAN 40. These are lab-only credentials, not production secrets.

**Design and build flow**

Before changing the plan, check the inventory arithmetic, model support, port capacity, and every requested cable endpoint. Show me two preview layouts at a time; each must keep the same 48 devices and logical topology. Wait for me to choose a design before building. Only then offer the `.pkt` build action.

After I choose, validate that there are exactly 48 devices, no duplicate IP addresses, no reused switch/router ports, and no missing cable endpoints. If something blocks the build, name the exact issue and provide a useful repair action. Do not report a repair as complete unless it changed the plan and the blocker was checked again. Build only the currently selected plan revision; if the plan changed, tell me and offer to build the current revision.
''';

NetworkIntent _parse(String brief) =>
    NetworkIntent.parseSimple('tri-site-resilient-services', brief);

void main() {
  test(
    'near-limit explicit inventory retains counts, names and exact models',
    () {
      final brief = CasualEnglish.normalize(nearLimitInventory);
      final intent = _parse(nearLimitInventory);
      final counts = <String, int>{};
      for (final node in intent.nodes) {
        counts.update(node.type, (count) => count + 1, ifAbsent: () => 1);
      }
      expect(NetworkIntent.classifyBrief(brief), 'build');
      expect(intent.nodes, hasLength(48));
      final exactLinks = intent.links.where((link) => link.exactPorts).toList();
      expect(exactLinks, hasLength(46));
      String connectionKey(NetLink link) =>
          '${link.a.toLowerCase()} ${link.aIf.toLowerCase()}>'
          '${link.b.toLowerCase()} ${link.bIf.toLowerCase()}';
      String reverseConnectionKey(NetLink link) =>
          '${link.b.toLowerCase()} ${link.bIf.toLowerCase()}>'
          '${link.a.toLowerCase()} ${link.aIf.toLowerCase()}';
      final actualConnections = <String>{
        for (final link in exactLinks) ...{
          connectionKey(link),
          reverseConnectionKey(link),
        },
      };
      expect(
        actualConnections,
        containsAll({
          'r-hq g0/0>sw-hq-dist g0/1',
          'r-east g0/0>sw-east g0/1',
          'r-west g0/0>sw-west g0/1',
          'sw-hq-dist g0/2>sw-hq-access g0/1',
          'r-hq g0/1>r-east g0/1',
          'r-east g0/2>r-west g0/1',
          'r-west g0/2>r-hq g0/2',
          'srv-01 f0>sw-hq-dist f0/1',
          'srv-08 f0>sw-hq-dist f0/8',
          'pc-hq-01 f0>sw-hq-dist f0/9',
          'pc-hq-08 f0>sw-hq-access f0/4',
          'pc-east-01 f0>sw-east f0/1',
          'pc-east-08 f0>sw-east f0/8',
          'pc-west-01 f0>sw-west f0/1',
          'pc-west-08 f0>sw-west f0/8',
          'ipph-hq-01 f0>sw-hq-dist f0/13',
          'ap-hq f0>sw-hq-dist f0/14',
          'ipph-east-01 f0>sw-east f0/9',
          'ipph-east-02 f0>sw-east f0/10',
          'ap-east f0>sw-east f0/11',
          'ipph-west-01 f0>sw-west f0/9',
          'ipph-west-02 f0>sw-west f0/10',
        }),
      );
      for (final link in exactLinks) {
        final routerToRouter =
            link.a.toLowerCase().startsWith('r-') &&
            link.b.toLowerCase().startsWith('r-');
        expect(
          link.cable,
          routerToRouter ? 'copper-cross' : 'copper',
          reason: '${link.a} ${link.aIf} to ${link.b} ${link.bIf}',
        );
      }
      expect(intent.nodes.where((node) => node.type == 'unknown'), isEmpty);
      expect(intent.nodes.where((node) => node.type == 'cloud'), isEmpty);
      expect(intent.nodes.where((node) => node.type == 'printer'), isEmpty);

      expect(counts, {
        'router': 3,
        'switch': 4,
        'pc': 24,
        'server': 8,
        'wireless': 2,
        'laptop': 2,
        'phone': 5,
      });

      for (final node in intent.nodes) {
        expect(
          node.exactModel,
          isTrue,
          reason: '${node.name} must keep its model',
        );
      }
      expect(
        intent.nodes
            .where((node) => node.type == 'router')
            .map((node) => node.model),
        everyElement('2911'),
      );
      expect(
        intent.nodes
            .where((node) => node.type == 'switch')
            .map((node) => node.model),
        everyElement('2960-24TT'),
      );
      expect(
        intent.nodes
            .where((node) => node.type == 'phone')
            .map((node) => node.model),
        everyElement('IP Phone-PT'),
      );

      final deviceNames = intent.nodes.map((node) => node.name).toSet();
      expect(
        deviceNames,
        containsAll([
          'R-HQ',
          'R-EAST',
          'R-WEST',
          'SW-HQ-DIST',
          'SW-HQ-ACCESS',
          'SW-EAST',
          'SW-WEST',
          'PC-HQ-01',
          'PC-HQ-08',
          'PC-EAST-01',
          'PC-EAST-08',
          'PC-WEST-01',
          'PC-WEST-08',
          'SRV-01',
          'SRV-08',
          'AP-HQ',
          'AP-EAST',
          'LT-HQ-01',
          'LT-EAST-01',
          'IPPH-HQ-01',
          'IPPH-WEST-02',
        ]),
      );
      expect(deviceNames, hasLength(48));
      for (final site in ['HQ', 'EAST', 'WEST']) {
        for (var i = 1; i <= 8; i++) {
          expect(
            deviceNames,
            contains('PC-$site-${i.toString().padLeft(2, '0')}'),
          );
        }
      }

      final buildabilityIssues =
          ValidatorService.validate(intent, target: 'packet-tracer').where((
            issue,
          ) {
            final message = issue.message.toLowerCase();
            return message.contains('no buildable template') ||
                message.contains('choose a device type or model');
          });
      expect(buildabilityIssues, hasLength(1));
      expect(buildabilityIssues.single.message, contains('IP Phone-PT'));
      expect(buildabilityIssues.single.message, contains('IPPH-HQ-01'));

      final addressedIps = intent.addressing
          .map((address) => address.ipCidr.split('/').first)
          .toList();
      expect(addressedIps.toSet(), hasLength(addressedIps.length));
      expect(
        intent.addressing.where((a) => a.node == 'SRV-01').single.ipCidr,
        '10.10.30.11/24',
      );
      expect(
        intent.addressing.where((a) => a.node == 'SRV-08').single.ipCidr,
        '10.10.30.18/24',
      );
      expect(
        intent.addressing
            .where((a) => a.node == 'R-HQ' && a.iface == 'g0/0.10')
            .single
            .ipCidr,
        '10.10.10.1/24',
      );
      expect(
        PacketTracerAdapter.endpointIpConfig(intent, 'PC-HQ-05')['gw'],
        '10.10.10.1',
      );
      expect(
        PacketTracerAdapter.endpointIpConfig(intent, 'PC-EAST-01')['gw'],
        '10.20.10.1',
      );

      final phoneGroup = PacketTracerModelCompatibility.unsupportedExactModels(
        intent,
      ).single;
      expect(phoneGroup.model, 'IP Phone-PT');
      expect(phoneGroup.count, 5);
      expect(
        PacketTracerModelCompatibility.compatibleModels(phoneGroup),
        contains('7960'),
      );
      final compatible = PacketTracerModelCompatibility.applyChoice(
        intent,
        phoneGroup,
        '7960',
      );
      expect(compatible.nodes, hasLength(48));
      expect(compatible.links, hasLength(46));
      expect(
        compatible.nodes
            .where((node) => node.type == 'phone')
            .map((node) => node.model),
        everyElement('7960'),
      );
      expect(
        PacketTracerModelCompatibility.unsupportedExactModels(compatible),
        isEmpty,
      );

      final switchConfigs = CiscoAdapter.render(intent);
      expect(switchConfigs['SW-HQ-DIST'], contains('switchport voice vlan 20'));
      expect(
        switchConfigs['SW-HQ-DIST'],
        contains('switchport trunk native vlan 99'),
      );
      expect(
        switchConfigs['SW-EAST'],
        contains('switchport trunk allowed vlan 10,20,40,99'),
      );
      expect(switchConfigs['SW-EAST'], isNot(contains('vlan 30')));
      final dhcp = PacketTracerAdapter.serverServices(intent, 'SRV-01')['dhcp'];
      expect((dhcp?['pools'] as List), hasLength(9));
      final dns = PacketTracerAdapter.serverServices(intent, 'SRV-02')['dns'];
      expect(
        (dns?['records'] as List).map((row) => (row as Map)['name']),
        containsAll(['intranet.lab', 'mail.lab']),
      );
      for (final laptop in ['LT-HQ-01', 'LT-EAST-01']) {
        final wireless =
            intent.nodes
                    .singleWhere((node) => node.name == laptop)
                    .serviceRules['wireless']
                as Map;
        expect(wireless['ssid'], 'LAB-STAFF');
        expect(wireless['psk'], 'LabWiFi!2026');
        expect(wireless['mode'], 'client');
        expect(
          PacketTracerAdapter.endpointIpConfig(intent, laptop)['ip'],
          '0.0.0.0',
        );
      }

      final issueMessages = ValidatorService.validate(
        intent,
        target: 'packet-tracer',
      ).map((issue) => issue.message).toList();
      expect(issueMessages, isNot(contains(startsWith('Duplicate IP '))));
      expect(
        issueMessages.where(
          (message) => message.contains('already carries another cable'),
        ),
        isEmpty,
      );
    },
  );

  test('a fresh complete inventory replaces a stale oversized chat plan', () {
    const oldBrief = '4 routers, 2 switches and 170 PCs';
    final oldPlan = _parse(oldBrief);
    expect(oldPlan.nodes, hasLength(176));

    final brief = CasualEnglish.normalize(nearLimitInventory);
    final parsed = _parse(nearLimitInventory);
    final outcome = NetworkIntent.followUp(
      previous: oldPlan,
      previousBrief: oldBrief,
      brief: brief,
      parsed: parsed,
      project: 'tri-site-resilient-services',
    );

    expect(outcome.plan.nodes, hasLength(48));
    expect(outcome.brief, brief);
    expect(outcome.plan.nodes.where((node) => node.type == 'unknown'), isEmpty);
  });

  test(
    'a long complete inventory survives the background parse path',
    () async {
      final parsed = await NetworkIntent.parseSimpleAsync(
        'tri-site-resilient-services',
        nearLimitInventory,
      );
      expect(parsed.nodes, hasLength(48));
      expect(parsed.links.where((link) => link.exactPorts), hasLength(46));
      expect(parsed.nodes.where((node) => node.type == 'cloud'), isEmpty);
      expect(parsed.nodes.where((node) => node.type == 'printer'), isEmpty);
    },
  );
}
