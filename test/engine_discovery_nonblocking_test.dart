// The PATH lookup must come off the UI isolate WITHOUT changing what it finds.
//
// The launch path used to call `Process.runSync('where.exe', ...)` four times
// on the UI isolate. That blocks the frame for the length of four process
// spawns, on the only path every desktop user takes, before the app has drawn
// anything. It is now asynchronous.
//
// The risk in that change is not the async-ness, it is the DRIFT: if the new
// lookup probed a different set of names, ordered results differently, or
// filtered differently, the app would silently start a different interpreter
// than before - and the only symptom would be a lab that builds on some
// machines. So the property under test is PARITY, plus the absence of the
// blocking call from the launch path itself.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/sidecar_supervisor.dart';

void main() {
  group('the async PATH lookup finds exactly what the sync one did', () {
    test('override lists are filtered identically by both paths', () async {
      // The Store shim must be dropped, blanks skipped, duplicates collapsed,
      // and first-seen order kept - the same rule both paths apply.
      const raw = [
        r'C:\Users\L\AppData\Local\Microsoft\WindowsApps\python.exe',
        '',
        '   ',
        r'C:\Python314\pythonw.exe',
        r'C:\Python314\pythonw.exe',
        r'C:\Python312\python.exe',
      ];

      final sync = SidecarSupervisor.pathInterpreters(raw);
      final async = await SidecarSupervisor.pathInterpretersAsync(raw);

      expect(async, sync, reason: 'the override path must not diverge');
      expect(async, [r'C:\Python314\pythonw.exe', r'C:\Python312\python.exe']);
    });

    test('the real PATH scan agrees between the two implementations', () async {
      if (!Platform.isWindows) {
        markTestSkipped('where.exe is a Windows lookup');
        return;
      }
      final sync = SidecarSupervisor.pathInterpreters();
      final async = await SidecarSupervisor.pathInterpretersAsync();

      expect(async, sync, reason: '''
        The two lookups must produce the SAME ordered list.
        Order decides which interpreter candidateTargets offers first, and
        _start takes the first one that verifies, so a reordering here is a
        silent change of which Python the engine runs under.
      ''');
    });

    test('the Store shim is dropped even when it is the only hit', () async {
      const raw = [r'C:\Users\L\AppData\Local\Microsoft\WindowsApps\python.exe'];
      expect(await SidecarSupervisor.pathInterpretersAsync(raw), isEmpty);
      expect(SidecarSupervisor.pathInterpreters(raw), isEmpty);
    });
  });

  group('the UI isolate is not blocked by PATH discovery', () {
    test('no blocking process call survives on the launch path', () {
      // Read the source rather than trusting the symbol names: the point is
      // that the BLOCKING call is gone from the code the app actually runs,
      // not merely that a new async function exists somewhere nearby.
      final source = File('lib/services/sidecar_supervisor.dart').readAsStringSync();

      // Every remaining `Process.runSync` must sit inside the sync `_where`,
      // which is now reachable only from the synchronous, test-facing
      // `pathInterpreters`. Count the CALL FORM, not the bare name: the
      // prose around these functions names `Process.runSync` while explaining
      // why it is gone, and a naive count matches the explanation too.
      final syncCalls =
          RegExp(r"Process\.runSync\(\s*'where\.exe'").allMatches(source).length;
      expect(syncCalls, lessThanOrEqualTo(1),
          reason: 'a new blocking process call was added');

      // The launch path must resolve PATH asynchronously.
      expect(source, contains('pythonsOnPath ?? await pathInterpretersAsync()'),
          reason: '''
        `_start` must resolve PATH with the async lookup before discovery.
        If it passed `pythonsOnPath` through as null, `candidateTargets`
        would fall back to the blocking sync path on the UI isolate - which is
        the exact regression this file exists to prevent.
      ''');
    });

    test('concurrent launches share ONE PATH scan', () async {
      // `ensureStarted` dedupes whole attempts, but a scan can still be
      // requested twice in quick succession. The in-flight memo means the
      // second caller waits on the first scan instead of spawning its own set
      // of `where.exe` processes.
      //
      // Asserting that all three callers got the same LIST would pass even
      // with the memo deleted - three independent scans of an unchanged PATH
      // return three equal lists. So this counts the scans instead: sharing
      // is the claim, and equal answers are not evidence for it.
      if (!Platform.isWindows) {
        markTestSkipped('where.exe is a Windows lookup');
        return;
      }
      final before = SidecarSupervisor.pathScanCount;
      final results = await Future.wait([
        SidecarSupervisor.pathInterpretersAsync(),
        SidecarSupervisor.pathInterpretersAsync(),
        SidecarSupervisor.pathInterpretersAsync(),
      ]);
      final scans = SidecarSupervisor.pathScanCount - before;

      expect(results[1], results[0]);
      expect(results[2], results[0]);
      expect(scans, 1,
          reason: '''
        Three concurrent callers ran $scans PATH scans. Each scan spawns four
        `where.exe` processes, so an unshared memo turns one lookup into
        twelve process spawns on the startup path.
      ''');
    });

    test('the memo is cleared, so a LATER scan is not served a stale answer',
        () async {
      // The memo is in-flight only. If it were cached forever, an
      // interpreter installed after the first launch would never be found -
      // a bug that would look like "the app cannot find Python any more".
      if (!Platform.isWindows) {
        markTestSkipped('where.exe is a Windows lookup');
        return;
      }
      final before = SidecarSupervisor.pathScanCount;
      await SidecarSupervisor.pathInterpretersAsync();
      await SidecarSupervisor.pathInterpretersAsync();
      final scans = SidecarSupervisor.pathScanCount - before;

      expect(scans, 2,
          reason: '''
        Two SEQUENTIAL calls ran $scans scans. The memo must dedupe only
        concurrent work; holding onto the result forever would mean an
        interpreter installed after startup is never discovered.
      ''');
    });
  });

  group('candidateTargets still builds the same candidate list', () {
    test('an explicit interpreter list needs no PATH scan at all', () {
      // The discovery function stays pure and synchronous: given the PATH
      // list it produces the same candidates it always did. This is what lets
      // the async work happen in `_start` without touching discovery.
      final targets = SidecarSupervisor.candidateTargets(
        roots: const [],
        pythonsOnPath: const [r'C:\Python314\python.exe'],
      );
      expect(targets, isEmpty,
          reason: 'no roots means no sidecar script to launch against');
    });
  });
}