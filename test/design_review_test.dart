// Every network the app builds gets read back by [DesignReviewer] - the
// "did what I just made actually hold together" check. These pin the rubric:
// it must spot the gaps that matter (a flat 30-host lab with no services, a
// single router carrying the whole site) and must NOT invent problems for a
// lab that is already well built, because a review that cries wolf on every
// build is the same as no review at all.
import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/design_review.dart';

NetworkIntent _plan(String brief) => NetworkIntent.parseSimple('chat', brief);

DesignReview _review(String brief) => DesignReviewer.review(_plan(brief));

bool _hasArea(DesignReview review, String area, DesignSeverity severity) =>
    review.findings.any((f) => f.area == area && f.severity == severity);

void main() {
  group('a well-built lab is not made to look bad', () {
    test('a small complete lab scores full marks', () {
      final review = _review('1 router, 1 switch, 2 PCs, DHCP and DNS');
      expect(review.score, 100);
      expect(review.verdict, 'solid');
      expect(review.findings, isEmpty);
      expect(review.strengths, isNotEmpty);
    });

    test('a redundant, secured, multi-router lab scores full marks', () {
      final review = _review(
        '2 routers with OSPF area 0, 2 switches, 3 servers, 20 PCs, DHCP, '
        'DNS, AAA, a firewall and a cloud',
      );
      expect(review.score, 100, reason: review.findings.map((f) => f.message).join(' | '));
      expect(review.verdict, 'solid');
    });

    test('strengths name what is right, not just what is wrong', () {
      final review = _review('1 router, 1 switch, 2 PCs, DHCP and DNS');
      expect(
        review.strengths.any((s) => s.contains('DHCP')),
        isTrue,
        reason: 'a review that only criticises is not a review',
      );
    });
  });

  group('it finds the gaps that matter', () {
    test('a flat lab with no services loses points for the right reasons', () {
      final review = _review('3 switches and 30 PCs');
      expect(review.score, lessThan(100));
      expect(review.verdict, isNot('solid'));
      expect(_hasArea(review, 'services', DesignSeverity.gap), isTrue);
    });

    test('one router carrying a big site is called a single point of failure', () {
      final review = _review('a warehouse with 60 staff');
      expect(
        review.findings.any(
          (f) => f.area == 'redundancy' && f.message.contains('single point'),
        ),
        isTrue,
      );
    });

    test('an internet-connected lab with no firewall is flagged', () {
      final plan = _plan('1 router, 1 switch, 1 cloud and 20 PCs');
      final review = DesignReviewer.review(plan);
      expect(review.score, lessThan(100));
    });

    test('a device with no cable is noticed', () {
      final review = _review('2 routers, 2 switches and 3 PCs');
      expect(
        review.findings.any((f) => f.area == 'structure'),
        isFalse,
        reason: 'a fully-connected lab must not be told it has orphans',
      );
    });

    test('an empty plan is unusable rather than perfect', () {
      const empty = NetworkIntent(
        projectName: 'nothing',
        nodes: [],
        links: [],
        addressing: [],
        vlans: [],
        routing: 'static',
        notes: [],
        assumptions: [],
        questions: [],
        confidence: 0,
        planningSource: 'test',
        security: SecurityIntent(),
        layout: {},
      );
      final review = DesignReviewer.review(empty);
      expect(review.verdict, 'unusable');
      expect(review.score, 0);
    });
  });

  group('the verdict tracks the findings', () {
    test('findings are ordered worst first', () {
      final review = _review('3 switches and 30 PCs');
      final rank = <DesignSeverity, int>{
        DesignSeverity.fault: 0,
        DesignSeverity.gap: 1,
        DesignSeverity.note: 2,
      };
      for (var i = 1; i < review.findings.length; i++) {
        expect(
          rank[review.findings[i - 1].severity]! <=
              rank[review.findings[i].severity]!,
          isTrue,
          reason: 'the list must read as a to-do list',
        );
      }
    });

    test('the headline is the worst thing to fix', () {
      final review = _review('3 switches and 30 PCs');
      expect(review.headline, review.findings.first.message);
    });

    test('the same plan always reviews the same way', () {
      final a = _review('2 routers, 2 switches and 10 PCs');
      final b = _review('2 routers, 2 switches and 10 PCs');
      expect(a.score, b.score);
      expect(a.verdict, b.verdict);
      expect(
        a.findings.map((f) => f.message).toList(),
        b.findings.map((f) => f.message).toList(),
      );
    });

    test('the score stays inside its bounds however bad it gets', () {
      for (final brief in [
        '',
        '1 PC',
        '10 servers',
        '5 routers, 20 switches and 200 PCs with no services',
      ]) {
        final review = _review(brief);
        expect(review.score, inInclusiveRange(0, 100));
      }
    });
  });
}