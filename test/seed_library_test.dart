// The seed library, proven against real Packet Tracer saves.
//
// A phone cannot run the Python sidecar, so the app has to learn device
// templates from a save the user already has. These tests use genuine saves
// written by Packet Tracer: if the extractor misreads a block, the app will
// clone the wrong hardware into a lab and nothing will say so.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:net_builder/services/pkt/seed_library.dart';

const List<String> realSaves = [
  'sidecar/demo-lab.pkt',
  'sidecar/pkt_seed/netbuilder-202609201923.pkt',
  'sidecar/pkt_seed/prompt-star.pkt',
  'sidecar/pkt_seed/resume-isr2911.pkt',
];

void main() {
  group('a seed save is indexed into usable templates', () {
    for (final path in realSaves) {
      final name = path.split('/').last;

      test('$name yields devices, not module fragments', () {
        final lib = SeedLibrary.fromPkt(File(path).readAsBytesSync());

        expect(lib.isEmpty, isFalse,
            reason: '$name must supply at least one device to clone');

        // Every entry must be a real device kind. A `<TYPE>` read from deep
        // in the module tree would file a router as 'eNonRemovableModule',
        // and the app would then be unable to build any router at all.
        for (final d in lib.devices) {
          // Every module type in the format starts with 'e' (eNonRemovable-
          // Module, eInterfaceCard, eSmartSerial). A device kind never does.
          expect(d.type.startsWith('e'), isFalse,
              reason: '$name: "${d.type}" is a module type, not a device');
          expect(d.type.trim(), isNotEmpty);
        }

        // A device block must carry its own engine and workspace, otherwise a
        // clone would be an empty husk.
        for (final d in lib.devices) {
          expect(d.xml, startsWith('<DEVICE>'));
          expect(d.xml, endsWith('</DEVICE>'));
          expect(d.xml, contains('<ENGINE>'));
          expect(d.xml, contains('<WORKSPACE>'));
        }
      });
    }

    test('every device in the save is found, and no more', () {
      // Counted straight off the XML: an extractor that silently dropped a
      // device would quietly shrink every lab built from that seed.
      for (final path in realSaves) {
        final xml = decryptPkt(File(path).readAsBytesSync());
        final text = String.fromCharCodes(xml);
        final expected = '<DEVICE>'.allMatches(text).length;
        final lib = SeedLibrary.fromPkt(File(path).readAsBytesSync());
        expect(lib.devices.length, expected,
            reason: '$path: the save has $expected devices');
      }
    });

    test('blocks do not overlap or run past their own end', () {
      for (final path in realSaves) {
        final lib = SeedLibrary.fromPkt(File(path).readAsBytesSync());
        final joined = lib.devices.map((d) => d.xml).join();
        expect('<DEVICE>'.allMatches(joined).length, lib.devices.length,
            reason: '$path: a block swallowed another');
      }
    });
  });

  group('the catalogue describes what can be built', () {
    test('reports kind, model and how many are available', () {
      final lib = SeedLibrary.fromPkt(File('sidecar/demo-lab.pkt')
          .readAsBytesSync());

      final cat = lib.catalogue;
      expect(cat, isNotEmpty);
      for (final entry in cat) {
        expect(entry.available, greaterThan(0));
        expect(entry.type.trim(), isNotEmpty);
      }
      // Sorted so the picker shows the same order every time.
      final types = [for (final e in cat) e.type];
      expect(types, orderedEquals([...types]..sort()));
    });

    test('the inventory counts every device it found', () {
      final lib = SeedLibrary.fromPkt(File('sidecar/demo-lab.pkt')
          .readAsBytesSync());
      final counted =
          lib.inventory.values.fold<int>(0, (sum, n) => sum + n);
      expect(counted, lib.devices.length);
    });
  });

  group('choosing a template', () {
    test('an exact model match is returned', () {
      final lib = SeedLibrary.fromPkt(File('sidecar/demo-lab.pkt')
          .readAsBytesSync());
      final routers = lib.devices.where((d) => d.type == 'Router');
      expect(routers, isNotEmpty);
      final target = routers.first;
      expect(lib.templateFor('Router', model: target.model)?.model,
          target.model);
    });

    test('without a model, the first device of that kind is returned', () {
      final lib = SeedLibrary.fromPkt(File('sidecar/demo-lab.pkt')
          .readAsBytesSync());
      expect(lib.templateFor('Router')?.type, 'Router');
    });

    test('the kind is matched loosely, as users say it', () {
      final lib = SeedLibrary.fromPkt(File('sidecar/demo-lab.pkt')
          .readAsBytesSync());
      expect(lib.templateFor('router')?.type, 'Router');
      expect(lib.templateFor('  SWITCH ')?.type, 'Switch');
    });

    test('a model the seed does not have is refused, not approximated', () {
      final lib = SeedLibrary.fromPkt(File('sidecar/demo-lab.pkt')
          .readAsBytesSync());
      // Substituting a nearby model would build a lab that opens but teaches
      // the wrong hardware - the quiet failure this whole class of bug is.
      expect(lib.templateFor('Router', model: 'no-such-model'), isNull);
      expect(lib.templateFor('Wireless Router'), isNull);
    });
  });

  group('refusing bad input', () {
    test('plain XML is not accepted as a seed', () {
      expect(
        () => SeedLibrary.fromPkt('<PACKETTRACER5></PACKETTRACER5>'.codeUnits),
        throwsA(isA<PktFormatError>()),
      );
    });

    test('a save with no devices yields an empty library, not an error', () {
      final lib = SeedLibrary.fromXml(
        '<PACKETTRACER5><NETWORK><DEVICES></DEVICES></NETWORK></PACKETTRACER5>',
      );
      expect(lib.isEmpty, isTrue);
      expect(lib.inventory, isEmpty);
      expect(lib.templateFor('Router'), isNull);
    });

    test('an unterminated device block is not returned half-open', () {
      final lib = SeedLibrary.fromXml(
        '<PACKETTRACER5><NETWORK><DEVICES><DEVICE><ENGINE>'
        '<TYPE model="2811">Router</TYPE></ENGINE></DEVICE></DEVICES>'
        '</NETWORK></PACKETTRACER5>',
      );
      expect(lib.devices, hasLength(1));
      expect(lib.devices.first.xml, endsWith('</DEVICE>'));
    });
  });
}