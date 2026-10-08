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
  port: 'port1',
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
  port: 'port1',
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
    'mcu',
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
];

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
