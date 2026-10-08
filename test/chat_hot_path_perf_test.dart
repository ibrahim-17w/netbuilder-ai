// Chat-screen hot-path performance regression gates.
//
// `dart_perf_gates_test.dart` covers planning and context budgeting; these
// cover the OTHER work the UI isolate pays for on every frame of a streaming
// answer. The chat screen rebuilds roughly every 12 ms while a reply arrives
// - one token, setState, whole tree - and every one of those rebuilds runs
// the same three things: ChatMarkdown.parse over the answer so far,
// ChatService.streamPreview over the raw payload so far, and
// ValidatorService.validate over the standing plan (NetworkInspector.build
// calls it with no target on every build). All three run on the UI isolate,
// so an accidental rescan is felt as dropped frames while the answer is
// still typing itself out, never as a failed test.
//
// These are CANARIES, not benchmarks: each ceiling sits far above today's
// measured cost so an ordinary slow CI machine does not trip them, while an
// accidental O(n^2) - or a loop added to a hot path - trips them immediately.
//
// Measured on the reference machine (2026-10-08, Flutter 3.44, debug VM):
//
//   parse long answer    2.0 ms    (195-line OSPF tutorial, 79 blocks)
//   parse short bubble   2.0 ms    (batch of 200; ~0.010 ms each)
//   streamPreview x200 130.0 ms    (growing 23k raw payload)
//   validate x3         10.0 ms    (54-device plan, no target)
//
// The streamPreview number is the one worth watching: a single call is
// cheap, but the screen calls it once per arriving chunk and each call
// rescans everything that arrived before it, so a 200-chunk reply pays the
// sum of 1..200. The parse numbers are paid per rebuild, so they are the
// ones that decide whether the stream visibly stutters - a short bubble is
// timed as a batch of 200 because one parse is below the clock's resolution.
//
// Ceilings are ~5x measured. Raise them deliberately and say why in the
// commit; do not quietly widen one to make a red build green.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/chat_service.dart';
import 'package:net_builder/services/validator_service.dart';
import 'package:net_builder/widgets/chat_markdown.dart';

/// Median of [runs] timed iterations, in milliseconds.
///
/// Median, not mean: one GC pause or one scheduling hiccup should not decide
/// whether a gate fires. Median is also what a user perceives - the typical
/// turn, not the unlucky one.
double medianMs(void Function() body, {int runs = 5}) {
  final samples = <double>[];
  for (var i = 0; i < runs; i++) {
    final t = DateTime.now().microsecondsSinceEpoch;
    body();
    samples.add((DateTime.now().microsecondsSinceEpoch - t) / 1000.0);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

NetworkIntent _lab() => NetworkIntent.parseSimple(
      'perf',
      '2 routers, 2 switches and 50 PCs with OSPF',
    );

/// A long answer the way the model actually writes one: headings, bullets,
/// numbered steps, two fenced configs, three pipe tables, inline code, bold,
/// a link and wrapped prose.
String _longAnswer() =>
    r'''# Configuring OSPF on the two-router lab

OSPF is what the planner picks when a brief asks for routing without naming a
protocol: it converges fast, needs no neighbour entries typed by hand, and it
keeps working while you are still cabling the rest of the lab. This is the
full walkthrough for the two-router topology this plan just designed.

## What the plan gives you

- `R1` and `R2` joined by a serial transit link
- Two switches carrying the 50 PCs from the brief
- One OSPF process, one area (`area 0`), so there is no ABR to reason about
- Every LAN-facing interface passive, so no hellos leave the LAN
- A loopback on each router, so the router ID never depends on a cable

## Address plan

| Device | Interface | IP | OSPF |
|---|---|---|---|
| R1 | g0/0 | 10.0.0.1/30 | area 0 |
| R1 | s0/0/0 | 10.0.0.5/30 | area 0 |
| R1 | lo0 | 10.255.0.1/32 | area 0 |
| R1 | g0/1 | 10.10.0.1/24 | passive |
| R2 | g0/0 | 10.0.0.2/30 | area 0 |
| R2 | s0/0/0 | 10.0.0.6/30 | area 0 |
| R2 | lo0 | 10.255.0.2/32 | area 0 |
| R2 | g0/1 | 10.20.0.1/24 | passive |

Transit links are `/30` so exactly two hosts fit and a stray third address
cannot be typed onto them by accident. Loopbacks are `/32` so a summary
route never drags a whole LAN behind it.

## Step by step

1. Set the hostname and clock on `R1`, because undated logs are useless later.
2. Address every interface in the table above, in the table's own order.
3. Start OSPF process `1` and network the transit, the LAN and the loopback.
4. Mark `g0/1` passive so the 25 PCs behind it never hear a protocol hello.
5. Repeat the same steps on `R2` with its own column of the table.
6. Watch the adjacency come up from `show ip ospf neighbor` on both routers.
7. Save the running config - Packet Tracer will not save it for you.

### On R1

```cisco
hostname R1
interface Loopback0
 ip address 10.255.0.1 255.255.255.255
interface GigabitEthernet0/0
 ip address 10.0.0.1 255.255.255.252
 ip ospf 1 area 0
interface Serial0/0/0
 ip address 10.0.0.5 255.255.255.252
 ip ospf 1 area 0
interface GigabitEthernet0/1
 ip address 10.10.0.1 255.255.255.0
 ip ospf 1 area 0
router ospf 1
 router-id 10.255.0.1
 passive-interface default
 no passive-interface Serial0/0/0
```

### On R2

```cisco
hostname R2
interface Loopback0
 ip address 10.255.0.2 255.255.255.255
interface GigabitEthernet0/0
 ip address 10.0.0.2 255.255.255.252
 ip ospf 1 area 0
interface Serial0/0/0
 ip address 10.0.0.6 255.255.255.252
 ip ospf 1 area 0
interface GigabitEthernet0/1
 ip address 10.20.0.1 255.255.255.0
 ip ospf 1 area 0
router ospf 1
 router-id 10.255.0.2
 passive-interface default
 no passive-interface Serial0/0/0
```

## Verifying it actually works

Three commands, in this order, and each one answers a different question:

1. `show ip ospf neighbor` - is the adjacency FULL, and what state is it in?
2. `show ip route ospf` - did an `O` route arrive for the far LAN?
3. `ping 10.20.0.1` from `R1` - does traffic really cross the transit link?

If all three answer the way you expect, the control plane and the data plane
agree and the lab is ready for the PCs.

### The neighbour table

| Neighbor | State | Address | Interface |
|---|---|---|---|
| 10.255.0.2 | FULL/- | 10.0.0.6 | Serial0/0/0 |
| 10.255.0.1 | FULL/- | 10.0.0.5 | Serial0/0/0 |

`FULL` is the only state that carries routes. `2WAY` is normal on a broadcast
LAN and is not a fault.

## When the adjacency does not come up

- **Dead in both directions** - the transit addresses are not in the same
  subnet; re-check the `/30` mask on both ends.
- **Stuck in `INIT`** - a hello is arriving but the reply is not; a firewall
  or an `access-list` is eating the return traffic.
- **Stuck in `EXSTART`** - the MTU differs across the link; set both ends to
  1500 and clear the process with `clear ip ospf process`.
- **No neighbour at all** - the interface has no `ip ospf 1 area 0` on it,
  or it was marked passive before the adjacency formed.

Clearing the process bounces every adjacency on the router, so do it once at
the end rather than once per fix.

## Reading the debug output

`debug ip ospf adjacency` prints one line per state change. Turn it off
afterwards with `no debug ip ospf adjacency` or `undebug all`, or the
console will keep you waiting on every hello timer. A quiet console is the
normal state; a busy one is a symptom worth chasing.

## The same lab on GNS3

Nothing above changes when the target is GNS3 instead of Packet Tracer, with
three exceptions worth knowing before you start:

- The serial interfaces are really named `Serial0/0/0`, so no remap happens
  and the address you typed is the address the interface carries.
- The switches are Ethernet bridges, so port counts are not enforced and the
  26-device switch in the plan is legal even though a real 2960 would refuse
  the last two cables.
- Saving writes a file to disk rather than a lab save inside the simulator,
  so `write memory` still matters but the topology survives a crash either
  way.

## Port reference for this plan

| Device | Port | Cabled to | Role |
|---|---|---|---|
| R1 | g0/0 | SW1 g0/1 | transit |
| R1 | s0/0/0 | R2 s0/0/0 | WAN |
| R1 | g0/1 | SW1 g0/2 | LAN |
| R2 | g0/0 | SW2 g0/1 | transit |
| R2 | s0/0/0 | R1 s0/0/0 | WAN |
| R2 | g0/1 | SW2 g0/2 | LAN |
| SW1 | g0/1 | R1 g0/0 | uplink |
| SW1 | g0/2 | R1 g0/1 | uplink |
| SW2 | g0/1 | R2 g0/0 | uplink |
| SW2 | g0/2 | R2 g0/1 | uplink |

## Mistakes worth not making

1. Addressing the two ends of the transit link in different subnets - by far
   the most common reason an adjacency never appears at all.
2. Writing `network 0.0.0.0 255.255.255.255 area 0` and then wondering why
   every interface, configured or not, joined the process.
3. Leaving `passive-interface default` on without the matching
   `no passive-interface Serial0/0/0`, which suppresses hellos exactly on the
   link where they matter.
4. Forgetting the loopback, so the router ID is picked from whichever
   interface came up first and changes whenever that link flaps.
5. Mixing wildcard masks and subnet masks in the `network` statements - the
   command wants the wildcard, so a host is `0.0.0.0` and not `255.255.255.255`.
6. Reading `FULL/-` next to `FULL/  -` from another device and concluding the
   two are different states; the spacing is cosmetic.
7. Deleting the whole OSPF process to fix one interface, which drops every
   other adjacency on that router at the same time.

## Rolling it back

- `no router ospf 1` removes the process and every route it installed.
- Clear an address with `no ip address` before re-addressing, otherwise the
  old one stays and the duplicate-address check rejects the new one.
- `show ip ospf database` afterwards should list nothing but this router's
  own entries.

## Timing and convergence

With two routers in a single area, convergence after a link flap is one dead
interval (40 seconds by default) plus an SPF run that measures in single-digit
milliseconds. Shortening the timers to `ip ospf hello-interval 10` and
`ip ospf dead-interval 40` makes a test rig fail over while you are watching
it; leave the defaults alone if any of this is ever copied onto real gear.

## Where to read more

The [RFC 2328](https://www.rfc-editor.org/rfc/rfc2328) is the whole protocol
in one document, and the Cisco design guide covers the design questions this
small lab cannot raise. Neither is required to finish this build: paste the
two blocks above, check the neighbour table, and the lab is done.''';

/// The one-sentence answer - the common case, a short bubble.
String _shortAnswer() =>
    'Add `ip ospf 1 area 0` on both ends of the transit link and the '
    'adjacency comes up by itself.';

const int _streamSteps = 200;

void main() {
  group('chat hot-path cost ceilings', () {
    test('parsing a 195-line answer stays under 10 ms, 200 short bubbles '
        'under 10 ms', () {
      final answer = _longAnswer();
      final short = _shortAnswer();

      final blocks = ChatMarkdown.parse(answer);
      expect(blocks, isNotEmpty,
          reason: 'the fixture must still parse into blocks at all');
      expect(blocks.length, 79, reason: '''
        The long fixture parsed into ${blocks.length} top-level blocks, not
        the 79 it was measured on - the fixture drifted, so the timings below
        are no longer comparable to the numbers in the header.
      ''');
      expect(
        blocks.map((b) => b.kind).toSet(),
        containsAll([
          MdKind.heading,
          MdKind.bullet,
          MdKind.code,
          MdKind.table,
          MdKind.paragraph,
        ]),
      );
      final codeBlocks = blocks.where((b) => b.kind == MdKind.code).toList();
      expect(codeBlocks, hasLength(2),
          reason: 'both fenced configs must survive the parse');
      expect(codeBlocks.first.language, 'cisco');
      expect(codeBlocks.first.text, contains('router ospf 1'));
      final tables = blocks.where((b) => b.kind == MdKind.table).toList();
      expect(tables, hasLength(3));
      expect(tables.first.header, ['Device', 'Interface', 'IP', 'OSPF']);
      expect(tables.first.rows, hasLength(8));
      expect(tables.last.header, ['Device', 'Port', 'Cabled to', 'Role']);
      expect(tables.last.rows, hasLength(10));

      final longMs = medianMs(() => ChatMarkdown.parse(answer));
      // One short parse sits below the clock's resolution, so a sample is a
      // batch of them and the batch is what gets gated.
      final shortBatchMs = medianMs(() {
        for (var i = 0; i < 200; i++) {
          ChatMarkdown.parse(short);
        }
      });

      expect(longMs, lessThan(10.0), reason: '''
        Parsing took ${longMs.toStringAsFixed(2)} ms (measured 2.0 ms).
        ChatMarkdown.parse runs on the UI isolate on EVERY rebuild of the
        chat screen - about every 12 ms while a reply streams in - so a
        quadratic scan of the answer shows up as the bubble stuttering
        mid-stream rather than as a failed build.
      ''');
      expect(shortBatchMs, lessThan(10.0), reason: '''
        Parsing 200 one-sentence bubbles took
        ${shortBatchMs.toStringAsFixed(2)} ms (measured 2.0 ms, about
        0.010 ms each). Short bubbles are the common case - every user
        message and every terse answer - so they must stay far cheaper than
        the long answer above, and a per-bubble cost that crept towards the
        12 ms rebuild budget would be visible as lag while typing.
      ''');
    });

    test('streaming 200 chunks of a growing 23k payload stays under 650 ms',
        () {
      final reply = List.filled(3, _longAnswer()).join('\n\n');
      final full = jsonEncode({'reply': reply, 'status': 'streaming'});
      final chunks = <String>[
        for (var i = 1; i <= _streamSteps; i++)
          full.substring(0, (full.length * i / _streamSteps).floor()),
      ];
      expect(chunks, hasLength(_streamSteps));

      final preview = ChatService.streamPreview(full);
      expect(preview, isNotNull,
          reason: 'a complete payload must produce a readable preview');
      expect(preview, reply, reason: '''
        The final preview did not decode back to the reply that was encoded.
        A "fast" streamPreview that returned a prefix, a truncated string or
        nothing at all would sail through the timing gate below while the
        chat screen showed the wrong text.
      ''');
      final mid = ChatService.streamPreview(chunks[_streamSteps ~/ 2]);
      expect(mid, isNotNull);
      expect(reply.startsWith(mid!), isTrue,
          reason: 'a half-arrived payload must preview as a prefix of it');

      final took = medianMs(() {
        for (final chunk in chunks) {
          ChatService.streamPreview(chunk);
        }
      }, runs: 3);

      expect(took, lessThan(650.0), reason: '''
        The ${chunks.length}-call streamPreview loop took
        ${took.toStringAsFixed(1)} ms (measured 130.0 ms for a
        ${full.length}-char payload). The chat screen calls this once per
        arriving chunk on the UI isolate, and every call rescans everything
        that arrived before it - a quadratic rescan here is exactly what
        turns a long answer into a stuttering frame rate.
      ''');
    });

    test('validating a 54-device lab three times stays under 50 ms', () {
      final intent = _lab();
      expect(intent.nodes.length, greaterThanOrEqualTo(54),
          reason: 'the fixture must stay the 54-device lab it was measured on');

      final first = ValidatorService.validate(intent);
      final second = ValidatorService.validate(intent);
      final third = ValidatorService.validate(intent);
      expect(first, isNotEmpty, reason: '''
        The validator returned nothing for the 54-device lab, so it is not
        doing the work these gates protect - a validator that early-outed to
        an empty list would be both wrong and very fast.
      ''');
      expect(second.length, first.length,
          reason: 'validate must be stable across consecutive builds');
      expect(third.length, first.length,
          reason: 'validate must be stable across consecutive builds');

      var counted = 0;
      final took = medianMs(() {
        for (var i = 0; i < 3; i++) {
          counted += ValidatorService.validate(intent).length;
        }
      });

      expect(counted, greaterThan(0), reason: '''
        Nothing was counted across the timed calls, so the body did not
        actually run - the gate would pass on an empty loop.
      ''');
      expect(took, lessThan(50.0), reason: '''
        Validating three times took ${took.toStringAsFixed(1)} ms (measured
        10.0 ms). NetworkInspector.build calls validate with no target on
        every build of the chat screen, so its cost is paid on the UI
        isolate alongside the parse and the stream preview.
      ''');
    });
  });
}
