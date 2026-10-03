// The on-device builder, proven by building from a real save and reading the
// result back.
//
// A build that "looks fine" is worthless: the whole risk is that the app
// produces a file which does not open. So every assertion here reads the
// ENCRYPTED output back through the codec and checks the save really contains
// what was asked for - the device, under its new name, at its new position,
// on a fresh identity.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/pkt/pkt_builder.dart';
import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:net_builder/services/pkt/seed_library.dart';

void main() {
  late SeedLibrary seed;

  setUp(() {
    seed = SeedLibrary.fromPkt(
      File('sidecar/demo-lab.pkt').readAsBytesSync(),
    );
  });

  String xmlOf(PktBuildResult r) => utf8.decode(decryptPkt(r.bytes));

  group('building devices on the device', () {
    test('the built file is a real, decryptable save', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [
          PktDeviceSpec(name: 'R1', type: 'Router', model: '2811'),
          PktDeviceSpec(name: 'SW1', type: 'Switch', model: '2960-24TT'),
        ],
      );

      expect(isPkt(result.bytes), isTrue);
      expect(result.bytes.length, greaterThan(1000));
      final xml = xmlOf(result);
      expect(xml.trimLeft().startsWith('<'), isTrue);
      expect(xml, contains('<PACKETTRACER5>'));
    });

    test('every requested device is in the save, under its own name', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [
          PktDeviceSpec(name: 'Edge1', type: 'Router', model: '2811'),
          PktDeviceSpec(name: 'Core1', type: 'Switch', model: '2960-24TT'),
          PktDeviceSpec(name: 'Desk1', type: 'Pc'),
        ],
      );
      expect(result.warnings, isEmpty);
      final xml = xmlOf(result);
      for (final name in ['Edge1', 'Core1', 'Desk1']) {
        expect(xml, contains('<NAME translate="true">$name</NAME>'),
            reason: '$name is missing from the built save');
      }
    });

    test('devices get distinct identities, so cables can be bound', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [
          PktDeviceSpec(name: 'R1', type: 'Router', model: '2811'),
          PktDeviceSpec(name: 'R2', type: 'Router', model: '2811'),
          PktDeviceSpec(name: 'R3', type: 'Router', model: '2811'),
        ],
      );
      expect(result.refIds.keys, containsAll(['R1', 'R2', 'R3']));
      expect(result.refIds.values.toSet(), hasLength(3),
          reason: 'two devices sharing a ref id binds every cable to one box');

      final xml = xmlOf(result);
      for (final id in result.refIds.values) {
        expect(xml, contains('save-ref-id:$id'));
      }
    });

    test('a device is placed where the plan asked', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [
          PktDeviceSpec(name: 'Placed', type: 'Router', model: '2811',
              x: 640, y: 480),
        ],
      );
      final xml = xmlOf(result);
      final start = xml.indexOf('<NAME translate="true">Placed</NAME>');
      expect(start, greaterThan(0));
      final block = xml.substring(start, xml.indexOf('</DEVICE>', start));
      expect(block, contains('<X>640</X>'));
      expect(block, contains('<Y>480</Y>'));
    });

    test('the seed name does not survive into the built save', () {
      // The template's own hostname leaking is the bug that made a generated
      // PC inherit the template source's name.
      final original = seed.devices.first.name;
      final result = PktBuilder.build(
        seed: seed,
        devices: const [PktDeviceSpec(name: 'Fresh', type: 'Router',
            model: '2811')],
      );
      final xml = xmlOf(result);
      final start = xml.indexOf('<NAME translate="true">Fresh</NAME>');
      final block = xml.substring(start, xml.indexOf('</DEVICE>', start));
      expect(block, isNot(contains('<NAME translate="true">$original</NAME>')));
    });

    test('the same plan builds the same file every time', () {
      const devices = [
        PktDeviceSpec(name: 'R1', type: 'Router', model: '2811'),
        PktDeviceSpec(name: 'SW1', type: 'Switch', model: '2960-24TT'),
      ];
      final a = PktBuilder.build(seed: seed, devices: devices);
      final b = PktBuilder.build(seed: seed, devices: devices);
      expect(a.bytes, b.bytes,
          reason: 'a build that changes on every run cannot be trusted');
    });
  });

  group('things it cannot do are said, not hidden', () {
    test('a model the seed lacks is reported and the rest still build', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [
          PktDeviceSpec(name: 'R1', type: 'Router', model: '2811'),
          PktDeviceSpec(name: 'Exotic', type: 'Router', model: 'ASR1001'),
        ],
      );
      expect(result.warnings, hasLength(1));
      expect(result.warnings.first, contains('Exotic'));
      // The one that CAN be built is still there: one unsupported model must
      // not cost the user the rest of the lab.
      expect(xmlOf(result), contains('<NAME translate="true">R1</NAME>'));
    });

    test('a seed with no devices is refused outright', () {
      final empty = SeedLibrary.fromXml(
        '<PACKETTRACER5><NETWORK><DEVICES></DEVICES></NETWORK></PACKETTRACER5>',
      );
      expect(
        () => PktBuilder.build(seed: empty, devices: const []),
        throwsA(isA<PktFormatError>()),
      );
    });
  });

  group('links', () {
    test('a cable is written between two built devices', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [
          PktDeviceSpec(name: 'R1', type: 'Router', model: '2811'),
          PktDeviceSpec(name: 'R2', type: 'Router', model: '2811'),
        ],
        links: const [
          PktLinkSpec(
            fromDevice: 'R1',
            fromPort: 'Serial0/0/0',
            toDevice: 'R2',
            toPort: 'Serial0/0/0',
            type: 'eSerial',
            dceAtFrom: true,
          ),
        ],
      );
      final xml = xmlOf(result);
      expect(xml, contains('<LINK>'));
      expect(xml, contains('save-ref-id:${result.refIds['R1']}'));
      expect(xml, contains('save-ref-id:${result.refIds['R2']}'));
      expect(xml, contains('<DCEPORT>Serial0/0/0</DCEPORT>'));
    });

    test('a link with a missing end is reported, not half-written', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [PktDeviceSpec(name: 'R1', type: 'Router',
            model: '2811')],
        links: const [
          PktLinkSpec(
            fromDevice: 'R1',
            fromPort: 'Serial0/0/0',
            toDevice: 'Ghost',
            toPort: 'Serial0/0/0',
          ),
        ],
      );
      expect(result.warnings.join(), contains('Ghost'));
    });
  });

  group('the rest of the save survives', () {
    test('the document keeps its options and scenarios', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [PktDeviceSpec(name: 'R1', type: 'Router',
            model: '2811')],
      );
      final xml = xmlOf(result);
      // These are the sections the app does not model. Dropping them is how a
      // save stops opening.
      expect(xml, contains('<OPTIONS>'));
      expect(xml, contains('<PHYSICALWORKSPACE>'));
      expect(xml, contains('<VERSION>'));
    });

    test('no XML-illegal control character survives into the file', () {
      final result = PktBuilder.build(
        seed: seed,
        devices: const [PktDeviceSpec(name: 'R1', type: 'Router',
            model: '2811')],
      );
      final xml = xmlOf(result);
      for (var i = 0; i < xml.length; i++) {
        final c = xml.codeUnitAt(i);
        expect(c <= 0x08 || c == 0x0B || c == 0x0C || (c >= 0x0E && c <= 0x1F),
            isFalse,
            reason: 'control character 0x${c.toRadixString(16)} at $i');
      }
    });
  });
}