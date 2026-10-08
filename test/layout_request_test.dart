import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/layout_intent.dart';

/// The devices a request moves, flattened out of whichever shape it used, so
/// a test can say "it asked for the servers" without caring whether the reader
/// put them in the single-group fields or in a zone.
List<String> movedKinds(LayoutRequest? r) {
  if (r == null) return const <String>[];
  return <String>[
    if (r.sideKinds.isNotEmpty) ...r.sideKinds,
    for (final z in r.zones) ...z.kinds,
  ];
}

List<String> movedNames(LayoutRequest? r) {
  if (r == null) return const <String>[];
  return <String>[
    if (r.sideNames.isNotEmpty) ...r.sideNames,
    for (final z in r.zones) ...z.names,
  ];
}

/// "server@left" for each zone, so a test can assert where groups went.
List<String> zoneEdges(LayoutRequest? r) => <String>[
  if (r != null)
    for (final z in r.zones)
      '${z.kinds.isEmpty ? z.names.join('+') : z.kinds.join('+')}@${z.edge}',
];

/// A request about the DRAWING has to produce a different drawing - the
/// whole reason this reader exists is that "make it look better" used to
/// recompile the same plan into byte-identical coordinates, which read as
/// being ignored.
void main() {
  group('requests that are about the drawing', () {
    test('a named style is honoured', () {
      expect(LayoutRequest.read('make the layout compact')?.style, 'compact');
      expect(
        LayoutRequest.read('spread the devices out')?.style,
        'wide',
      );
      expect(
        LayoutRequest.read('put each kind of device on its own row')?.style,
        'rows',
      );
      expect(
        LayoutRequest.read('draw it as site trees again')?.style,
        'tree',
      );
    });

    test('a vague request still changes the drawing', () {
      // "not this one" is a decision: the next style, never the same one.
      final request = LayoutRequest.read(
        'can you edit the layout of the devices to make them better looking?',
        currentStyle: 'tree',
      );
      expect(request, isNotNull);
      expect(request!.style, isNot('tree'));
      expect(request.explicitStyle, isFalse);
    });

    test('a vague request after a compact build picks something else', () {
      final request = LayoutRequest.read('it looks ugly', currentStyle: 'compact');
      expect(request, isNotNull);
      expect(request!.style, isNot('compact'));
    });

    test('a column count is read and marks the request explicit', () {
      final digits = LayoutRequest.read('6 devices per row please');
      expect(digits?.columns, 6);
      expect(digits?.explicitStyle, isTrue);
      final words = LayoutRequest.read('four pcs to a row');
      expect(words?.columns, 4);
    });

    test('phrasing a redraw names the other options, not the current one', () {
      final options = LayoutRequest.optionsFor('tree');
      expect(options, isNotEmpty);
      expect(options, everyElement(isNot(contains('site trees'))));
      expect(LayoutRequest.nextStyle('grid'), 'tree');
    });

    test('the vague cycle is one drawing per ALGORITHM', () {
      // Cycling between two sizes of the same tree is what made every redraw
      // look the same. Two sizes may share a silhouette; the cycle may not.
      expect(LayoutRequest.styles, isNot(contains('wide')));
      expect(LayoutRequest.styles, isNot(contains('compact')));
      expect(LayoutRequest.styles, isNot(contains('grouped')));
      for (final style in LayoutRequest.styles) {
        expect(LayoutRequest.nextStyle(style), isNot(style));
      }
      // Every drawing is reachable, and every cycle entry is a real drawing.
      expect(
        LayoutRequest.styles.every(LayoutRequest.allStyles.contains),
        isTrue,
      );
    });

    test('every drawing can be asked for by name', () {
      for (final style in LayoutRequest.allStyles) {
        final phrase = LayoutRequest.phraseFor(style);
        expect(
          LayoutRequest.read(phrase)?.style,
          style,
          reason: 'the gallery chip "$phrase" does not ask for $style',
        );
      }
    });

    test('the style survives a note round-trip', () {
      expect(LayoutRequest.styleFromNote('built from the plan; layout: wide'),
          'wide');
      expect(LayoutRequest.styleFromNote('layout: compact'), 'compact');
      expect(LayoutRequest.styleFromNote('no note here'), '');
      expect(LayoutRequest.styleFromNote('layout: nonsense'), '');
    });

    test('the payload the engine reads carries the style', () {
      expect(LayoutRequest(style: 'wide').toPayload(), {'style': 'wide'});
      expect(LayoutRequest(style: 'rows', columns: 6).toPayload(), {
        'style': 'rows',
        'columns': 6,
      });
    });
  });

  // Every sentence below is one that used to come back as a normal plan
  // re-analysis, or as a redraw that silently did the wrong thing. They are
  // the reported failure, written down.
  group('ordinary wording about the drawing is understood', () {
    test('"make it wider" and "more space" are not thrown away', () {
      // These failed the old topic gate: "wider" and "space" were in the
      // NAMED-style patterns but the gate rejected the sentence before any of
      // them was read, so the most ordinary redraw requests did nothing.
      expect(LayoutRequest.read('make it wider')?.style, 'wide');
      expect(
        LayoutRequest.read('more space between devices')?.style,
        'wide',
      );
      expect(LayoutRequest.read('make it wider')?.explicitStyle, isTrue);
      expect(LayoutRequest.read('make it normal')?.style, 'tree');
      expect(LayoutRequest.read('reset the layout')?.style, 'tree');
    });

    test('moving devices to one side is a real request, not a plan edit', () {
      for (final text in [
        'put the servers on one side not near the pcs',
        'move the servers to the side',
        'move this device to the side',
        'move the servers aside',
        'separate the servers from the pcs',
      ]) {
        final request = LayoutRequest.read(text);
        expect(request, isNotNull, reason: 'dropped: "$text"');
        expect(request!.style, 'grouped', reason: 'not grouped: "$text"');
        expect(movedKinds(request), contains('server'), reason: text);
        expect(request.isGrouped, isTrue, reason: text);
      }
    });

    test('the edge is read from the sentence', () {
      expect(zoneEdges(LayoutRequest.read('move the servers to the right')),
          ['server@right']);
      expect(
        zoneEdges(LayoutRequest.read('group the routers on the right')),
        ['router@right'],
      );
      expect(zoneEdges(LayoutRequest.read('move the servers to the left')),
          ['server@left']);
      expect(zoneEdges(LayoutRequest.read('move the servers aside')),
          ['server@left']);
    });

    test('the devices named are the ones that move', () {
      expect(
        movedKinds(LayoutRequest.read('move the routers to the right')),
        ['router'],
      );
    });

    test('devices named only as the ones to move away from stay put', () {
      // "not near the pcs" and "from the PCs" are the TARGET of the move, not
      // part of it. Reading the PCs as devices to move relocates the whole
      // host bank - the opposite of what was asked.
      for (final text in [
        'put the servers on one side not near the pcs',
        'separate the servers from the pcs',
        'move the servers away from the routers',
      ]) {
        final request = LayoutRequest.read(text);
        expect(movedKinds(request), ['server'], reason: text);
        expect(movedKinds(request), isNot(contains('host')), reason: text);
        expect(movedKinds(request), isNot(contains('router')), reason: text);
      }
    });

    test('a device named after the separation is not the one that moves', () {
      expect(
        movedNames(LayoutRequest.read('move SRV1 away from SRV2')),
        ['SRV1'],
      );
    });

    test('naming one device does not move every device of its kind', () {
      // "SRV1" must not be read as the kind "server", or one request would
      // relocate the whole server bank.
      final request = LayoutRequest.read('move SRV1 to the side');
      expect(movedNames(request), ['SRV1']);
      expect(movedKinds(request), isNot(contains('server')));
    });

    test('a placement naming no devices says so instead of pretending', () {
      final request = LayoutRequest.read('move it to the side');
      expect(request?.guessedSide, isTrue);
      expect(request?.explicitStyle, isFalse);
      expect(movedKinds(request), LayoutRequest.defaultSideKinds);
    });

    test('a count in the sentence is not read as a device name', () {
      final request = LayoutRequest.read('move 3 servers to the side');
      expect(movedNames(request), isEmpty);
      expect(movedKinds(request), ['server']);
      expect(request?.guessedSide, isFalse);
    });
  });

  // "put the servers on one side and the routers on the other" is two groups,
  // not one group with two kinds in it.
  group('a request can send different devices to different sides', () {
    test('"one side ... the other" is two groups', () {
      final request = LayoutRequest.read(
        'put the servers on one side and the routers on the other',
      );
      expect(request?.style, 'grouped');
      expect(zoneEdges(request), ['server@left', 'router@right']);
    });

    test('"here and there" is two groups', () {
      expect(
        zoneEdges(LayoutRequest.read('move the servers here and the routers there')),
        ['server@left', 'router@right'],
      );
    });

    test('left and right named outright is two groups', () {
      expect(
        zoneEdges(
          LayoutRequest.read('move the servers to the left and the routers to the right'),
        ),
        ['server@left', 'router@right'],
      );
      expect(
        zoneEdges(
          LayoutRequest.read('put the pcs on the right and the servers on the left'),
        ),
        ['host@right', 'server@left'],
      );
    });

    test('two groups named after one side are ONE group', () {
      // "move the servers AND the routers to the left" is not two requests to
      // put two things on the same side; it is one group on the left.
      final request = LayoutRequest.read(
        'move the servers and the routers to the left',
      );
      expect(zoneEdges(request), ['server+router@left']);
    });

    test('"these devices here and there" is still answered, and admits it', () {
      // No device named: the app must still redraw rather than drop the turn,
      // and must say which set it assumed.
      final request = LayoutRequest.read('move these devices here and there');
      expect(request, isNotNull);
      expect(request!.style, 'grouped');
      expect(request.guessedSide, isTrue);
      expect(movedKinds(request), LayoutRequest.defaultSideKinds);
    });

    test('two zones reach the engine payload', () {
      final request = LayoutRequest.read(
        'put the servers on one side and the routers on the other',
      );
      final payload = request!.toPayload();
      expect(payload['style'], 'grouped');
      final zones = payload['zones'] as List;
      expect(zones, hasLength(2));
      expect((zones[0] as Map)['sideKinds'], ['server']);
      expect((zones[0] as Map)['sideEdge'], 'left');
      expect((zones[1] as Map)['sideKinds'], ['router']);
      expect((zones[1] as Map)['sideEdge'], 'right');
    });

    test('zones survive a note round-trip', () {
      final request = LayoutRequest.read(
        'put the servers on one side and the routers on the other',
      );
      final note = LayoutRequest.noteFor(
        request!.style,
        zones: <LayoutZoneRequest>[
          for (final zone in request.zones)
            LayoutZoneRequest(
              kinds: zone.kinds,
              names: zone.names,
              edge: zone.edge,
            ),
        ],
      );
      expect(LayoutRequest.styleFromNote(note), 'grouped');
      final back = LayoutRequest.zonesFromNote(note);
      expect(back, hasLength(2));
      expect(back[0].kinds, ['server']);
      expect(back[0].edge, 'left');
      expect(back[1].kinds, ['router']);
      expect(back[1].edge, 'right');
    });
  });

  group('a grouped drawing can never be a silent no-op', () {
    test('grouped is not in the blind cycle', () {
      // With no devices named, `grouped` draws exactly the tree. If the vague
      // cycle could land on it, "make it look better" would hand back
      // identical coordinates - the one failure this reader exists to stop.
      expect(LayoutRequest.styles, isNot(contains('grouped')));
      for (final style in LayoutRequest.styles) {
        expect(LayoutRequest.nextStyle(style), isNot('grouped'));
      }
    });

    test('but it is offered, and phrased as something the reader accepts', () {
      expect(LayoutRequest.allStyles, contains('grouped'));
      final phrase = LayoutRequest.phraseFor('grouped');
      expect(LayoutRequest.read(phrase)?.style, 'grouped');
      expect(LayoutRequest.optionsFor('tree'), contains(phrase));
    });
  });

  group('the note carries the whole drawing', () {
    test('a grouped note round-trips style, devices and edge', () {
      final note = LayoutRequest.noteFor(
        'grouped',
        sideKinds: const ['server'],
        sideNames: const ['SRV1', 'SRV2'],
        sideEdge: 'right',
      );
      expect(LayoutRequest.styleFromNote(note), 'grouped');
      expect(LayoutRequest.sideKindsFromNote(note), ['server']);
      expect(LayoutRequest.sideNamesFromNote(note), ['SRV1', 'SRV2']);
      expect(LayoutRequest.sideEdgeFromNote(note), 'right');
    });

    test('a plain note is unchanged by the new format', () {
      final note = LayoutRequest.noteFor('wide');
      expect(note, 'layout: wide');
      expect(LayoutRequest.styleFromNote(note), 'wide');
      expect(LayoutRequest.sideKindsFromNote(note), isEmpty);
      expect(LayoutRequest.sideNamesFromNote(note), isEmpty);
    });

    test('a note written by an older build still reads', () {
      expect(LayoutRequest.styleFromNote('build verified; layout: wide'), 'wide');
      expect(LayoutRequest.styleFromNote('layout: banana'), '');
    });
  });

  group('words that are not about a drawing stay out of it', () {
    test('a device change is still an edit', () {
      expect(LayoutRequest.read('add 2 servers to the layout'), isNull);
      expect(LayoutRequest.read('remove the servers'), isNull);
      expect(LayoutRequest.read('make it 2 routers and 20 PCs'), isNull);
    });

    test('ordinary English that used to be a false positive is not', () {
      // Bare "apart" and "reset" were read as drawing requests, which turned
      // networking talk into a redraw.
      expect(LayoutRequest.read('2 subnets apart'), isNull);
      expect(LayoutRequest.read('reset the router'), isNull);
      expect(LayoutRequest.read('make the subnet smaller'), isNull);
      expect(LayoutRequest.read('the switch is bigger'), isNull);
    });

    test('genuine redraws by those words still work', () {
      expect(LayoutRequest.read('spread them further apart')?.style, 'wide');
      expect(LayoutRequest.read('reset the layout to normal')?.style, 'tree');
    });
  });

  // The four engineer drawings. A style the gallery offers has to be one the
  // reader can name, phrase, stamp into a note and read back - or the pick
  // silently reverts to the default on the next build.
  group('the engineer drawings: backbone, campus, star, ring', () {
    test('the gallery chip phrasing reads back as its style', () {
      for (final style in const ['backbone', 'campus', 'star', 'ring']) {
        final phrase = LayoutRequest.phraseFor(style);
        expect(
          LayoutRequest.read(phrase)?.style,
          style,
          reason: 'the gallery chip "$phrase" does not ask for $style',
        );
      }
    });

    test('ordinary wording names them', () {
      expect(
        LayoutRequest.read('draw it as a backbone with a riser')?.style,
        'backbone',
      );
      expect(LayoutRequest.read('make it a two tier campus')?.style, 'campus');
      expect(
        LayoutRequest.read('draw a star topology from the router')?.style,
        'star',
      );
      expect(LayoutRequest.read('hub and spoke please')?.style, 'star');
      expect(LayoutRequest.read('put the devices in a ring')?.style, 'ring');
      expect(LayoutRequest.read('ring topology')?.style, 'ring');
    });

    test('the older drawings keep their sentences', () {
      // "rings around" stays radial: the ring reader must not steal it, and
      // "one circle" stays circle.
      expect(
        LayoutRequest.read('draw it as rings around the core')?.style,
        'radial',
      );
      expect(
        LayoutRequest.read('put every device in one circle')?.style,
        'circle',
      );
      expect(
        LayoutRequest.read('restart the router')?.style,
        isNull,
        reason: '"restart" is not a star request',
      );
    });

    test('the style survives a note round-trip', () {
      for (final style in const ['backbone', 'campus', 'star', 'ring']) {
        final note = LayoutRequest.noteFor(style);
        expect(LayoutRequest.styleFromNote(note), style, reason: note);
      }
    });

    test('the payload the engine reads carries the style', () {
      expect(LayoutRequest(style: 'star').toPayload(), {'style': 'star'});
      expect(LayoutRequest(style: 'ring').toPayload(), {'style': 'ring'});
    });

    test('they join the vague cycle, which still skips grouped', () {
      expect(
        LayoutRequest.styles,
        containsAll(['backbone', 'campus', 'star', 'ring']),
      );
      expect(LayoutRequest.styles, isNot(contains('grouped')));
      expect(LayoutRequest.styles, isNot(contains('wide')));
      expect(LayoutRequest.styles, isNot(contains('compact')));
      for (final style in LayoutRequest.styles) {
        expect(LayoutRequest.nextStyle(style), isNot(style));
        expect(LayoutRequest.nextStyle(style), isNot('grouped'));
      }
      expect(LayoutRequest.nextStyle('grid'), 'tree');
    });
  });
}
