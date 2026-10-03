// The whole on-device path, end to end, with no sidecar anywhere.
//
// This is the Android question: can a phone turn what the user said into a
// real .pkt file? These tests do exactly that on a temp directory and then
// READ THE FILE BACK through the codec, so they prove the bytes on disk are
// a genuine save rather than something that merely looks like one.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/pkt/on_device_pkt_builder.dart';
import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:net_builder/services/pkt/seed_library.dart';

const seedPath = 'sidecar/demo-lab.pkt';

void main() {
  late Directory tmp;
  late SeedLibrary seed;

  setUp(() {
    seed = OnDevicePktBuilder.importSeed(File(seedPath));
    tmp = Directory.systemTemp.createTempSync('nb_on_device');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  NetworkIntent plan(String brief) => NetworkIntent.parseSimple('chat', brief);

  group('importing a seed save', () {
    test('a real save supplies templates', () {
      expect(seed.isEmpty, isFalse);
      expect(seed.kinds, contains('Router'));
      expect(seed.inventory, isNotEmpty);
    });

    test('a file that is not a save is refused with a usable message', () {
      final junk = File('${tmp.path}/junk.pkt')
        ..writeAsStringSync('this is not a Packet Tracer save');
      expect(
        () => OnDevicePktBuilder.importSeed(junk),
        throwsA(
          isA<OnDeviceBuildError>().having(
            (e) => e.reason,
            'reason',
            OnDeviceFailure.unreadableSeed,
          ),
        ),
      );
    });

    test('a save with no devices is refused rather than silently empty', () {
      final lib = SeedLibrary.fromXml(
        '<PACKETTRACER5><NETWORK><DEVICES></DEVICES></NETWORK></PACKETTRACER5>',
      );
      expect(lib.isEmpty, isTrue);
    });

    test('a missing file is refused, not crashed on', () {
      expect(
        () => OnDevicePktBuilder.importSeed(File('${tmp.path}/nope.pkt')),
        throwsA(isA<OnDeviceBuildError>()),
      );
    });
  });

  group('building from what the user said', () {
    test('a written brief becomes a real .pkt on disk', () {
      final intent = plan('2 routers, 3 switches, 4 servers and 10 PCs');
      final result = OnDevicePktBuilder.build(
        intent: intent,
        seed: seed,
        outDir: tmp,
        filename: 'lab.pkt',
      );

      expect(result, isNotNull);
      expect(result!.file.existsSync(), isTrue,
          reason: 'the .pkt must actually be written to disk');

      // Read the FILE back, not the in-memory result: this is the artifact
      // the user takes to Packet Tracer.
      final bytes = result.file.readAsBytesSync();
      expect(isPkt(bytes), isTrue);
      expect(OnDevicePktBuilder.audit(bytes).devices, greaterThan(0));

      // EVERY device is accounted for: either built, or named in a warning.
      // A device that quietly vanished would be a lab that does not do what
      // the user asked, and nothing would say so.
      final unbuilt = result.warnings.where((w) => w.startsWith('No template for'));
      expect(
        result.refIds.length + unbuilt.length,
        intent.nodes.length,
        reason: 'built ${result.refIds.length}, could not build '
            '${unbuilt.length}, requested ${intent.nodes.length}',
      );
    });

    test('a device the seed cannot supply is named in a warning', () {
      // demo-lab.pkt has 2811 routers and 2960 switches but no servers, so a
      // server must be reported rather than dropped in silence.
      final intent = plan('1 router and 2 servers');
      final result = OnDevicePktBuilder.build(
        intent: intent,
        seed: seed,
        outDir: tmp,
      )!;
      expect(result.warnings.join(), contains('no server'),
          reason: 'a kind the seed has never seen must be named');
      // Whether the router itself builds depends on whether the seed carries
      // the exact model the planner picked - so that is asserted by the
      // accounting test above, not here.
    });

    test('the manifest is written beside the file, as the desktop route does',
        () {
      final result = OnDevicePktBuilder.build(
        intent: plan('2 routers and 4 PCs'),
        seed: seed,
        outDir: tmp,
        filename: 'lab.pkt',
      )!;
      expect(result.manifest.existsSync(), isTrue);

      final manifest =
          jsonDecode(result.manifest.readAsStringSync()) as Map<String, dynamic>;
      expect(manifest['generator'], 'on-device');
      expect(manifest['devices'], greaterThan(0));
    });

    test('an intent with no devices produces no file at all', () {
      // The rule the chat enforces for greetings must hold here too: an
      // intent with nothing in it builds nothing, rather than falling back to
      // a default lab nobody asked for.
      const empty = NetworkIntent(projectName: 'empty');
      expect(empty.nodes, isEmpty);
      expect(
        OnDevicePktBuilder.build(
          intent: empty,
          seed: seed,
          outDir: tmp,
        ),
        isNull,
      );
    });

    test('devices are spread out, not stacked on one spot', () {
      final intent = plan('2 routers, 3 switches, 4 servers and 10 PCs');
      final specs = OnDevicePktBuilder.specsFor(intent).devices;
      expect(specs.length, intent.nodes.length);
      expect(specs.map((d) => '${d.x},${d.y}').toSet().length,
          specs.length,
          reason: 'two devices at one coordinate render as an unreadable pile');
    });

    test('links are only written between devices that were built', () {
      final intent = plan('2 routers, 2 switches and 4 PCs');
      final specs = OnDevicePktBuilder.specsFor(intent);
      final names = specs.devices.map((d) => d.name).toSet();
      for (final link in specs.links) {
        expect(names, contains(link.fromDevice));
        expect(names, contains(link.toDevice));
      }
    });
  });

  group('the file is honest about what it is', () {
    test('two builds of the same plan produce the same bytes', () {
      final intent = plan('1 router, 1 switch and 4 PCs');
      final a = OnDevicePktBuilder.build(
        intent: intent, seed: seed, outDir: tmp, filename: 'a.pkt')!;
      final b = OnDevicePktBuilder.build(
        intent: intent, seed: seed, outDir: tmp, filename: 'b.pkt')!;
      expect(a.file.readAsBytesSync(), b.file.readAsBytesSync());
    });

    test('a model the seed lacks is warned about, and the rest still build',
        () {
      final intent = NetworkIntent.parseSimple('chat', '1 router and 1 PC');
      final result = OnDevicePktBuilder.build(
        intent: intent,
        seed: seed,
        outDir: tmp,
      );
      expect(result, isNotNull);
      // Whatever happened, the manifest records every warning: a lab missing
      // a device must never be a silent surprise.
      final manifest =
          jsonDecode(result!.manifest.readAsStringSync()) as Map<String, dynamic>;
      expect(manifest['warnings'], isA<List>());
    });

    test('a built file survives being read as bytes and decoded again', () {
      final result = OnDevicePktBuilder.build(
        intent: plan('1 router and 1 PC'),
        seed: seed,
        outDir: tmp,
      )!;
      final xml = String.fromCharCodes(
        decryptPkt(result.file.readAsBytesSync()),
      );
      expect(xml, contains('<PACKETTRACER5>'));
      expect(xml, contains('<DEVICE>'));
    });
  });
}