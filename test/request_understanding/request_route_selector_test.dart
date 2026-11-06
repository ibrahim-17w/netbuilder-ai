import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/file_edit_intent.dart';
import 'package:net_builder/services/request_understanding/request_route_selector.dart';

void main() {
  test('a polite direct edit is routed to the general plan coordinator', () {
    final route = RequestRouteSelector.select(
      text: 'can you add 2 PCs?',
      hasArtifact: true,
      artifactCandidates: 2,
    );

    expect(route.helpOnly, isFalse);
    expect(route.coordinatorOwnsPlan, isTrue);
    expect(route.fileIntent, FileEditIntent.none);
  });

  test('an explanation question stays on the help path', () {
    final route = RequestRouteSelector.select(
      text: 'what is OSPF?',
      hasArtifact: true,
    );

    expect(route.dispatch, RequestDispatch.helpOnly);
    expect(route.coordinatorOwnsPlan, isFalse);
  });

  test('a file edit stays with the file reader', () {
    final route = RequestRouteSelector.select(
      text: 'edit the file and add one AAA server',
      hasArtifact: true,
      artifactCandidates: 1,
    );

    expect(route.dispatch, RequestDispatch.specialized);
    expect(route.fileIntent, FileEditIntent.editExisting);
    expect(route.coordinatorOwnsPlan, isFalse);
  });

  test('a layout change stays with the layout reader', () {
    final route = RequestRouteSelector.select(
      text: 'move the servers to the right',
      hasArtifact: true,
    );

    expect(route.dispatch, RequestDispatch.specialized);
    expect(route.layoutRequest, isNotNull);
    expect(route.coordinatorOwnsPlan, isFalse);
  });

  test('a named network design stays with the design reader', () {
    final route = RequestRouteSelector.select(
      text: 'use the DMZ design',
      hasArtifact: false,
    );

    expect(route.dispatch, RequestDispatch.specialized);
    expect(route.hasNamedDesign, isTrue);
    expect(route.coordinatorOwnsPlan, isFalse);
  });

  test('early candidates retain the established handler order', () {
    final selection = RequestRouteSelector.selectEarly(
      text: 'add a router and two PCs',
      isEditing: false,
      hasPendingAttachments: false,
    );

    expect(selection.answerSmallTalkImmediately, isFalse);
    expect(selection.handlers, const [
      EarlyRequestHandler.command,
      EarlyRequestHandler.rememberedRouting,
      EarlyRequestHandler.undo,
      EarlyRequestHandler.packetAnalysisFollowup,
      EarlyRequestHandler.scanDiff,
      EarlyRequestHandler.lab,
      EarlyRequestHandler.packetTracerModelChoice,
      EarlyRequestHandler.planRepair,
    ]);
  });

  test(
    'pure config and report matches are inserted at their old positions',
    () {
      final config = RequestRouteSelector.selectEarly(
        text: 'Current configuration : 120 bytes\nhostname R1',
        isEditing: false,
        hasPendingAttachments: false,
      );
      final report = RequestRouteSelector.selectEarly(
        text: 'export a lab report',
        isEditing: false,
        hasPendingAttachments: false,
      );

      expect(
        config.handlers.indexOf(EarlyRequestHandler.configPaste),
        config.handlers.indexOf(EarlyRequestHandler.undo) - 1,
      );
      expect(
        report.handlers.indexOf(EarlyRequestHandler.labReport),
        report.handlers.indexOf(EarlyRequestHandler.packetTracerModelChoice) -
            1,
      );
      expect(
        report.handlers.indexOf(EarlyRequestHandler.lab),
        lessThan(report.handlers.indexOf(EarlyRequestHandler.labReport)),
      );
    },
  );

  test('edits skip every early handler', () {
    final selection = RequestRouteSelector.selectEarly(
      text: 'undo that',
      isEditing: true,
      hasPendingAttachments: false,
    );

    expect(selection.answerSmallTalkImmediately, isFalse);
    expect(selection.handlers, isEmpty);
  });

  test('greetings take the immediate path only without attachments', () {
    final greeting = RequestRouteSelector.selectEarly(
      text: 'hello',
      isEditing: false,
      hasPendingAttachments: false,
    );
    final withAttachment = RequestRouteSelector.selectEarly(
      text: 'hello',
      isEditing: false,
      hasPendingAttachments: true,
    );

    expect(greeting.answerSmallTalkImmediately, isTrue);
    expect(greeting.handlers, isEmpty);
    expect(withAttachment.answerSmallTalkImmediately, isFalse);
    expect(withAttachment.handlers, isNotEmpty);
  });
}
