import '../../models/network_intent.dart';

/// The vocabularies the parser reads a brief through.
///
/// These lived inside network_intent.dart, which meant the data model and the
/// English reader could not be reasoned about separately: adding a device kind
/// meant editing the file that also defines NetLink. They are here now, and
/// they are the first half of splitting that file - the second half is the
/// parser itself, in parser.dart.
///
/// Nothing in here is behaviour. It is all lookup tables, and every one of
/// them is a place where the app's idea of the English language is written
/// down in a way a test can point at.

/// Every device the planner can place, and the words that name it.
const List<DeviceKind> deviceKinds = [
  DeviceKind(
    type: 'router',
    keywords: ['router'],
    models: ['4331', '2911', '1941', '4321', '2901', '829'],
    port: 'f0',
    cli: true,
  ),
  DeviceKind(
    type: 'wireless-router',
    // Packet Tracer's Wireless Router-PT: a router with a wireless AP inside.
    // Its own keyword, so 'wireless router' never reads as a plain AP (an AP
    // has no routing or NAT) - and no CLI either, because PT drives it from
    // the same GUI a home router has.
    keywords: ['wireless router'],
    models: ['Wireless Router-PT'],
    port: 'ethernet1',
  ),
  DeviceKind(
    type: 'switch',
    keywords: ['multilayer switch', 'layer 3 switch', 'switch'],
    models: ['2960', '2950', '3560'],
    port: 'f0',
    cli: true,
  ),
  DeviceKind(
    type: 'pc',
    keywords: ['pc', 'workstation', 'desktop computer'],
    models: ['PC-PT'],
    port: 'f0',
    ipConfig: true,
  ),
  DeviceKind(
    type: 'laptop',
    keywords: ['laptop', 'notebook'],
    models: ['Laptop-PT'],
    port: 'f0',
    ipConfig: true,
    wireless: true,
  ),
  DeviceKind(
    type: 'server',
    keywords: ['server'],
    models: ['Server-PT'],
    port: 'f0',
    ipConfig: true,
  ),
  DeviceKind(
    type: 'printer',
    keywords: ['printer'],
    models: ['Printer-PT'],
    port: 'f0',
    ipConfig: true,
  ),
  DeviceKind(
    type: 'meraki-server',
    // Packet Tracer's Meraki dashboard host, not a Cisco IOS controller.
    // Its dashboard is configured in PT's GUI, so it is placed and cabled
    // from its real template and deliberately given no CLI config.
    keywords: ['meraki server', 'meraki dashboard', 'meraki'],
    models: ['Meraki-Server'],
    port: 'f0',
  ),
  DeviceKind(
    type: 'firewall',
    // ASA-5506/5505 are Firewall-PT devices with ASA syntax, not IOS: they
    // are placed and cabled, and their config is deliberately left to the
    // user rather than filled with wrong `hostname`/`interface` lines.
    keywords: ['firewall', 'asa'],
    models: ['5506', '5505', 'ASA5505'],
    port: 'g1/1',
  ),
  DeviceKind(
    type: 'wireless',
    keywords: ['wireless access point', 'access point', 'wireless ap', 'ap'],
    models: ['AccessPoint-PT', 'AccessPoint-PT-A', 'AccessPoint-PT-N'],
    // The AP's Ethernet port: Packet Tracer names it from the host module and
    // never writes it into a save, so the manifest recorded it empty and every
    // cable to an AP was dropped ("port1 not usable on AP1" - the AP floated).
    // The library now names it FastEthernet0, which is what a real save uses.
    port: 'FastEthernet0',
    wireless: true,
  ),
  DeviceKind(
    type: 'wlc',
    keywords: ['wireless controller', 'wireless lan controller', 'wlc'],
    models: ['2504', 'WLC-PT'],
    // Its PT port menu has no stable name across builds: placed, not wired.
  ),
  DeviceKind(
    type: 'phone',
    keywords: ['ip phone', 'voip phone', 'phone'],
    models: ['7960', '7961', '7962'],
    // Same shape as the access point: the port is named from the host module,
    // so the library's FastEthernet0 is the name a real save uses.
    port: 'FastEthernet0',
  ),
  DeviceKind(
    type: 'tablet',
    keywords: ['tablet'],
    models: ['Tablet-PT'],
    wireless: true,
  ),
  DeviceKind(
    type: 'smartphone',
    keywords: ['smartphone', 'smart phone', 'mobile phone'],
    models: ['Smartphone-PT'],
    wireless: true,
  ),
  DeviceKind(
    type: 'tv',
    keywords: ['smart tv', 'tv'],
    models: ['TV-PT'],
    wireless: true,
  ),
  DeviceKind(
    type: 'wired-end-device',
    keywords: ['wired end device', 'wired endpoint'],
    models: ['WiredEndDevice-PT'],
    port: 'f0',
  ),
  DeviceKind(
    type: 'wireless-end-device',
    keywords: ['wireless end device', 'wireless endpoint'],
    models: ['WirelessEndDevice-PT'],
    wireless: true,
  ),
  DeviceKind(
    type: 'cloud',
    keywords: ['cloud', 'isp', 'internet'],
    models: ['Cloud-PT'],
    port: 'ethernet1',
  ),
  DeviceKind(
    type: 'modem',
    keywords: ['cable modem', 'dsl modem', 'modem'],
    models: ['DSL Modem-PT', 'Cable Modem-PT', 'Modem-PT'],
    port: 'port1',
  ),
  DeviceKind(
    type: 'iot',
    // The household things a home lab names instead of saying "IoT": a brief
    // that asked for "4 smart bulbs" was counted as no devices at all (the
    // word 'iot' never appeared), so the bulbs it asked for were never
    // placed.
    keywords: [
      'iot',
      'home gateway',
      // "mcu" has its own DeviceKind below; keeping it here counted one
      // request as both an IoT device and an MCU.
      'iot server',
      'smart bulb',
      'bulb',
      'smart plug',
      'smart camera',
      'smart lock',
      'thermostat',
      'doorbell',
      'smart sensor',
      'sensor',
    ],
    models: ['Home Gateway-PT', 'MCU-PT', 'IoT Server-PT'],
    // IoT devices join through the gateway/registration server, and the PT
    // port menu differs per model: placed with a wireless assumption instead
    // of a guessed cable.
    wireless: true,
  ),
  // The kinds below have real Packet Tracer templates AND a taught live
  // palette path (see DEVICE_PALETTE in sidecar/catalog.py): they build
  // offline and place live.
  DeviceKind(
    type: 'hub',
    keywords: ['hub'],
    models: ['Hub-PT'],
    port: 'f0',
  ),
  DeviceKind(
    type: 'bridge',
    keywords: ['bridge', 'bridge'],
    models: ['Bridge-PT'],
  ),
  DeviceKind(
    type: 'repeater',
    keywords: ['repeater', 'repeater'],
    models: ['Repeater-PT'],
  ),
  DeviceKind(
    type: 'mcu',
    keywords: ['mcu', 'microcontroller', 'mcu'],
    models: ['MCU-PT'],
  ),
  DeviceKind(
    type: 'sbc',
    keywords: ['sbc', 'single board computer', 'sbc'],
    models: ['SBC-PT'],
  ),
  DeviceKind(
    type: 'plc',
    keywords: ['plc', 'programmable logic controller'],
    models: ['PLC-PT'],
    port: 'g0',
  ),
  DeviceKind(
    type: 'analog-phone',
    keywords: ['analog-phone', 'analog phone'],
    models: ['Analog-Phone-PT'],
  ),
  DeviceKind(
    type: 'voip-adapter',
    keywords: ['voip-adapter', 'voip adapter'],
    models: ['Home-VoIP-PT'],
  ),
  DeviceKind(
    type: 'cell-tower',
    keywords: ['cell-tower', 'cell tower'],
    models: ['Cell-Tower'],
  ),
  DeviceKind(
    type: 'central-office',
    keywords: ['central-office', 'central office server'],
    models: ['Central-Office-Server'],
  ),
  DeviceKind(
    type: 'controller',
    // The parser's overlap rule ignores this short word inside a longer
    // "wireless lan controller" or "programmable logic controller", so a real
    // WLC/PLC request is not also counted as a generic controller.
    keywords: ['controller', 'network controller', 'meraki controller'],
    models: ['NetworkController'],
    port: 'g0',
  ),
  DeviceKind(
    type: 'sniffer',
    keywords: ['sniffer', 'packet sniffer'],
    models: ['Sniffer'],
    port: 'ethernet0',
  ),
  DeviceKind(
    type: 'historian',
    keywords: ['historian', 'data historian'],
    models: ['DataHistorianServer'],
    port: 'g0',
  ),
  DeviceKind(
    type: 'cyber-observer',
    keywords: ['cyber-observer', 'cyber observer', 'cyberobserver'],
    models: ['CyberObserver'],
    port: 'g0',
  ),
  DeviceKind(
    type: 'power-distribution',
    keywords: [
      'power-distribution',
      'power distribution',
      'power distribution device',
    ],
    models: ['Power Distribution Device'],
  ),
];

/// Kinds the offline compiler can build from Packet Tracer's own templates,
/// but that the live executor has no palette path for yet.
///
/// The offline `.pkt` is the product's primary build path, so these devices
/// are plan-able, analyzable and compile into a real file. A live autopilot
/// run reports each one as `offline_only` instead of substituting a different
/// device shape; see `OFFLINE_ONLY_DEVICE_KINDS` in `sidecar/catalog.py`
/// (`sidecar/test_device_palette.py` keeps the two lists equal).
///
/// Empty since the seven industrial/control kinds were taught live palette
/// paths (they build offline AND place live now). The set stays as the
/// landing place for the next offline-buildable kind with no click-path.
const Set<String> offlineOnlyDeviceKinds = {
  'meraki-server',
  'wired-end-device',
  'wireless-end-device',
  'analog-phone',
  'voip-adapter',
};

/// Kinds the planner can recognize but neither builder can place yet.
///
/// They stay in [deviceKinds] so a brief that names one still parses into a
/// visible node the user can correct, instead of making the device disappear.
/// [ValidatorService] rejects them before a build, and the sidecar mirrors
/// this list in `pt_autopilot.UNSUPPORTED_DEVICE_KINDS`
/// (`sidecar/test_device_palette.py` keeps the two equal). Do not put a kind
/// here once its palette and executor exist; add it to `DEVICE_PALETTE`.
const Set<String> unsupportedDeviceKinds = {
  'bridge',
  'repeater',
  'mcu',
  'sbc',
  'cell-tower',
  'central-office',
};

/// The device kinds a Packet Tracer build can actually place today.
final Set<String> supportedDeviceKinds = Set.unmodifiable({
  for (final kind in deviceKinds)
    if (!unsupportedDeviceKinds.contains(kind.type)) kind.type,
});

/// The default name prefix for a device kind ("R", "SW", "PC").
const Map<String, String> devicePrefixes = {
  'firewall': 'FW',
  'wireless': 'AP',
  'wireless-router': 'WR',
  'wlc': 'WLC',
  'phone': 'PH',
  'tablet': 'TAB',
  'smartphone': 'SP',
  'tv': 'TV',
  'cloud': 'CLOUD',
  'modem': 'MODEM',
  'iot': 'IOT',
  'laptop': 'LT',
  'printer': 'PRN',
  'hub': 'HUB',
  'sniffer': 'SNIFF',
  'plc': 'PLC',
  'historian': 'HIST',
  'cyber-observer': 'CYBER',
  'controller': 'CTRL',
  'power-distribution': 'PDU',
  'meraki-server': 'MERAKI',
  'wired-end-device': 'WED',
  'wireless-end-device': 'WLD',
};

/// Spelled-out numbers, bridged to digits before anything reads them.
const Map<String, int> numberWords = {
  'one': 1,
  'single': 1,
  'two': 2,
  'couple': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'pair': 2,
  'pairs': 2,
  'dozen': 12,
  'واحد': 1,
  'اثنان': 2,
  'اثنين': 2,
  'اثنتين': 2,
  'ثلاثه': 3,
  'ثلاث': 3,
  'اربعه': 4,
  'اربع': 4,
  'خمسه': 5,
  'خمس': 5,
  'سته': 6,
  'ست': 6,
  'سبعه': 7,
  'سبع': 7,
  'ثمانيه': 8,
  'ثمان': 8,
  'تسعه': 9,
  'تسع': 9,
  'عشره': 10,
  'عشر': 10,
};

/// Irregular plurals. "pcs" has no regular English plural, so the
/// suffix rule alone cannot see it; the table carries the ones that lie.
const Map<String, String> kindPlurals = {
  'router': 'routers',
  'switch': 'switches',
  'pc': 'PCs',
  'server': 'servers',
  'phone': 'phones',
  'printer': 'printers',
  'laptop': 'laptops',
  'firewall': 'firewalls',
  'access point': 'access points',
  'ap': 'access points',
};
