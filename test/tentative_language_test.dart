import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/casual_english.dart';
import 'package:net_builder/services/tentative_language.dart';

/// The gate runs on CasualEnglish-normalized text - that is what the chat
/// hands it - so every sentence here goes through the same normalizer before
/// the verdict: typos fixed, filler ("just", "please") stripped, punctuation
/// dropped from word edges (and with it the sentence boundaries).
TentativeVerdict verdictOf(String raw) =>
    TentativeLanguageService.analyze(CasualEnglish.normalize(raw));

void expectTentative(String raw) {
  final v = verdictOf(raw);
  expect(v.tentative, isTrue,
      reason: '"$raw" should read as exploration; cues: ${v.cues}');
  expect(v.cues, isNotEmpty,
      reason: 'a tentative verdict should name the cue that fired');
}

void expectDefinite(String raw) {
  final v = verdictOf(raw);
  expect(v.tentative, isFalse,
      reason: '"$raw" is a request and must stay free to mutate the plan; '
          'cues: ${v.cues}');
  expect(v.cues, isNotEmpty,
      reason: 'a definite verdict should name the signal that decided it');
}

void main() {
  group('exploration frames are tentative', () {
    test('the flagship sentence: wondering about scale', () {
      // No edit verb anywhere - "do it" is not one - so the modal question
      // holds the lab and the chat answers conversationally. This is the
      // sentence that used to re-plan the lab to 40 PCs.
      expectTentative('could we do it with 40 pcs?');
    });

    test('what if', () {
      // "used" is past tense, not the imperative "use", so nothing definite
      // is present and the what-if frame holds.
      expectTentative('what if we used ospf instead?');
      // Even a present-tense edit verb stays tentative while it sits under
      // the frame's "we": the order drops the frame ("add a dmz").
      expectTentative('what if we add a dmz?');
    });

    test("suppose, hypothetically, imagine, let's say", () {
      expectTentative('suppose the office grows to 60 users?');
      expectTentative('hypothetically, 3 switches instead of 2?');
      expectTentative('imagine two sites instead of one');
      expectTentative("let's say 40 pcs instead of 20");
    });

    test('hedges and design musing', () {
      expectTentative('maybe two routers instead of one');
      expectTentative('perhaps a second router');
      expectTentative('i am thinking about 40 pcs');
      expectTentative('considering a dmz in front of the servers');
    });

    test('topic-floating questions', () {
      expectTentative('how about a dmz');
      expectTentative('what about wireless');
      expectTentative('is it possible to run one flat network?');
      expectTentative('what would happen if we dropped the router?');
    });

    test('feasibility and comparison wondering', () {
      expectTentative('would a layer 3 switch work here');
      expectTentative('maybe ospf would be better?');
      expectTentative('could this work with one router?');
    });
  });

  group('borderline questions hold the lab when no edit verb exists', () {
    test('should we / shall we stay advice questions', () {
      // The chat routes questions to the advisor anyway, but if such a
      // sentence also parses as a plan (counts in it), it must not mutate.
      expectTentative('should we separate guest wifi into its own vlan?');
      expectTentative('or should we keep it flat?');
      expectTentative('shall we add a second isp?');
    });

    test('would you recommend / would you do', () {
      expectTentative('would you recommend a router for this?');
      expectTentative('could you recommend a router for this?');
      expectTentative('would you do it with a layer 3 switch?');
      expectTentative('would you do it with 40 pcs?');
    });

    test('the subject-first we-modal ("we could ...")', () {
      // Same exploration as "could we ...", just with the subject up front.
      expectTentative('we could do it with 40 pcs');
      expectTentative('we could add a dmz');
    });

    test('can/could we + an edit verb is a request, not musing', () {
      // A definite verb stays a definite edit whatever frame it sits in: a
      // person who says "can we add AAA to it?" is asking for the AAA, and
      // answering "that was a what-if" is how a chat stops being useful. The
      // planner-level merge for that exact sentence is pinned separately in
      // follow_up_plan_test.dart, and the chat that routes it is pinned in
      // chat_ui_test.dart.
      expectDefinite('could we add a dmz?');
      expectDefinite('can we add a dmz?');
      // The exploration that must survive: the we-modal with NO edit verb.
      expectTentative('could we do it with 40 pcs?');
      // "build it WITH a spec" is the what-if shape, not the run-the-build
      // ask (that one is tested as definite below) - the build verb is
      // deliberately outside the we-request vocabulary.
      expectTentative('could we build it with 2 routers instead?');
      // A frame still wins over the request reading.
      expectTentative('what if we could add a dmz?');
    });

    test('the green light inside a what-if stays a what-if', () {
      expectTentative('what if we go ahead with 40 pcs?');
    });
  });

  group('definite edit requests are never tentative', () {
    test('add / remove / delete', () {
      expectDefinite('add 2 access points');
      expectDefinite('add a dmz behind the router');
      expectDefinite('remove the second router');
      expectDefinite('delete the dmz');
    });

    test('count corrections', () {
      expectDefinite('make it 8');
      expectDefinite('no wait, make it 8 pcs');
      expectDefinite('actually 8 pcs');
      expectDefinite('actually, use eigrp');
    });

    test('declarative protocol and device changes', () {
      expectDefinite('use ospf instead of static');
      // The request can arrive mid-turn, after normalization ate the comma.
      expectDefinite('static is slow, use ospf instead');
      expectDefinite('switch to static routing');
      expectDefinite('replace r1 with a 4331');
      expectDefinite('change the routing to eigrp');
      expectDefinite('set ospf on r1');
    });

    test('stated needs and wants are requests', () {
      expectDefinite('i need 3 switches and a router');
      expectDefinite('we need a server for dhcp');
      expectDefinite('i will need more than 1 router');
      expectDefinite('i want 40 pcs');
    });

    test('build and plan verbs', () {
      expectDefinite('build it');
      // "just" is filler CasualEnglish strips, so the normalized turn is
      // "build it"; the lead-word tolerance also catches it un-stripped.
      expectDefinite('just build it');
      expectDefinite('build it anyway');
      expectDefinite('plan for 40 users');
      expectDefinite('create 3 vlans');
      expectDefinite('rebuild the lab with 2 routers');
      expectDefinite('give me a dmz behind the router');
    });
  });

  group('polite imperatives are requests, not exploration', () {
    test('can/could/would you + edit verb', () {
      // The imperative verb wins over the interrogative frame: these ask
      // the assistant to DO something.
      expectDefinite('can you add 2 access points?');
      expectDefinite('could you make it 8?');
      expectDefinite('would you add a server?');
      expectDefinite('can you please remove the dmz?');
      expectDefinite('could you switch to ospf?');
    });

    test('the polite frame alone does not make a request definite', () {
      // "recommend" is not an edit verb, so this stays an advice question.
      expectTentative('would you recommend a router for this?');
    });
  });

  group('a definite signal wins over tentative framing', () {
    test('the mixed turn: what-if opening, polite imperative closing', () {
      // One turn, two sentences after normalization ate the "?" - the
      // polite imperative in the second decides it.
      expectDefinite('what if we added a dmz? can you add it');
    });

    test('soft orders still order', () {
      // "maybe" in front of a bare imperative is a softened order; the
      // wondering form carries the "we": "maybe we add a server".
      expectDefinite('maybe add a server');
    });

    test('the green light wins over could-we', () {
      expectDefinite('could we go ahead and build it');
    });

    test('the run-the-build ask wins over the question shape', () {
      expectDefinite('can we build it now?');
      expectDefinite('can we just build it?');
    });

    test('a correction before a trailing topic question still stands', () {
      // The frame guard only suppresses a marker that sits AFTER an
      // exploration frame; here the correction opens the turn. Harmless
      // either way - "what about wireless" parses as no plan - but it pins
      // the direction of the guard.
      expectDefinite('actually, what about wireless?');
    });
  });

  group('empty and punctuation-only turns are not tentative', () {
    test('they carry no cues and hold nothing back', () {
      for (final raw in ['', '   ', '???', '...', '.', '!!!']) {
        final v = verdictOf(raw);
        expect(v.tentative, isFalse, reason: '"$raw"');
        expect(v.cues, isEmpty, reason: '"$raw"');
      }
    });

    test('analyze is tolerant of raw un-normalized text too', () {
      // The contract is normalized input, but the service lowercases and
      // trims itself, so a mixed-case turn still reads correctly.
      final v = TentativeLanguageService.analyze('What if we used OSPF?');
      expect(v.tentative, isTrue);
      expect(v.cues, contains('what if'));
    });
  });

  group('a quiet turn stays quiet (the default)', () {
    test('plain briefs carry no cues in either direction', () {
      // The gate is a tripwire, not a general classifier: a turn with no
      // exploration cue and no definite signal keeps the chat's existing
      // behaviour. It must read as "not tentative" so a plan still happens.
      for (final raw in [
        'a router 2 switches and 20 pcs',
        'the office has 40 users',
      ]) {
        final v = verdictOf(raw);
        expect(v.tentative, isFalse, reason: '"$raw"');
        expect(v.cues, isEmpty, reason: '"$raw"');
      }
    });
  });

  group('cues are debuggable', () {
    test('a tentative verdict names its cue', () {
      final v = verdictOf('what if we used ospf instead?');
      expect(v.cues, contains('what if'));
    });

    test('a definite verdict names the deciding signal', () {
      final v = verdictOf('can you add 2 aps?');
      expect(v.cues, contains('can you add'));
    });

    test('in a mixed turn the definite signal comes first', () {
      final v = verdictOf('what if we added a dmz? can you add it');
      expect(v.cues.first, 'can you add');
    });
  });
}
