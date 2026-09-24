import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/autopilot_service.dart';

void main() {
  group('CorrectionSnapshot parsing', () {
    test('reads stale, rejected, pending and thrash rows from /corrections', () {
      final snap = CorrectionSnapshot.fromJson({
        'ok': true,
        'summary': {
          'count': 4,
          'proposed': 1,
          'verified': 2,
          'rejected': 1,
          'stale': 1,
          'hits': 7,
          'corrections': [],
        },
        'corrections': [],
        'pending': [
          {
            'id': 'c3',
            'status': 'proposed',
            'failureKind': 'model_click_missed',
            'project': 'lab1',
            'device': 'R1',
            'dtype': 'router',
            'thrash': 0,
            'hits': 0,
            'misses': 0,
          },
        ],
        'stale': [
          {
            'id': 'c1',
            'status': 'verified',
            'stale': true,
            'failureKind': 'pc_spot',
            'device': 'PC0',
            'hits': 5,
            'misses': 3,
            'thrash': 2,
          },
        ],
        'thrash': [
          {
            'id': 'c1',
            'status': 'verified',
            'stale': true,
            'thrash': 2,
          },
        ],
      });

      expect(snap.hasStale, isTrue);
      expect(snap.stale.single.id, 'c1');
      expect(snap.stale.single.summaryLine, contains('PC0'));
      expect(snap.pending.single.status, 'proposed');
      expect(snap.thrash.single.thrash, 2);
      expect(snap.proposedCount, 1);
      expect(snap.verifiedCount, 2);
      expect(snap.hits, 7);
    });

    test('falls back to the listing for rejected rows on an older sidecar',
        () {
      final snap = CorrectionSnapshot.fromJson({
        'ok': true,
        'summary': {
          'count': 1,
          'rejected': 1,
          'corrections': [
            {
              'id': 'c9',
              'status': 'rejected',
              'failureKind': 'srv_button',
              'rejectReason': 'step did not verify',
            },
          ],
        },
        'corrections': [],
        'pending': [],
        'stale': [],
        'thrash': [],
      });

      expect(snap.rejected.single.id, 'c9');
      expect(snap.rejected.single.rejectReason, 'step did not verify');
    });

    test('tolerates missing or malformed fields', () {
      final snap = CorrectionSnapshot.fromJson({
        'summary': 'not-a-map',
        'pending': ['garbage', 42, null, {}],
        'stale': null,
      });

      expect(snap.isEmpty, isTrue);
      expect(snap.hasStale, isFalse);
      expect(snap.proposedCount, 0);
    });
  });

  group('TeachRunSnapshot parsing', () {
    test('indexes /status teachResults by correction id', () {
      final snap = TeachRunSnapshot.fromJson({
        'running': false,
        'teachRun': [],
        'teachResults': [
          {'correctionId': 'c1', 'promoted': true, 'promotion': 'PC|dtype||k'},
          {
            'correctionId': 'c2',
            'promoted': false,
            'status': 'rejected',
            'reason': 'step did not verify',
          },
          {'correctionId': 'c3', 'promoted': false, 'pending': true},
          {'promoted': true}, // no id -> ignored
        ],
      });

      expect(snap.byId['c1']?.promoted, isTrue);
      expect(snap.byId['c2']?.promoted, isFalse);
      expect(snap.byId['c2']?.reason, 'step did not verify');
      expect(snap.byId['c3']?.pending, isTrue);
      expect(snap.byId.length, 3);
    });

    test('empty on old sidecars without teachResults', () {
      expect(TeachRunSnapshot.fromJson({}).isEmpty, isTrue);
    });
  });
}
