import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/session_state.dart';

void main() {
  test('pending context round trip keeps project, revision and property', () {
    final state = SessionState()
      ..setPendingQuestions(const [
        PendingQuestionContext(
          questionId: 'routing',
          project: 'P1',
          baseRevision: 'rev-123',
          property: 'routing',
        ),
      ]);

    final restored = SessionState.decode(state.encode());
    expect(restored.pendingQuestionIds, ['routing']);
    expect(restored.pendingQuestionContexts, hasLength(1));
    expect(restored.pendingQuestionContexts.single.project, 'P1');
    expect(restored.pendingQuestionContexts.single.baseRevision, 'rev-123');
    expect(restored.pendingQuestionContexts.single.property, 'routing');
  });

  test('legacy ID-only pending questions decode without a false anchor', () {
    final restored = SessionState.decode('''
      {"pendingQuestionIds":["scale","routing"]}
    ''');

    expect(restored.pendingQuestionIds, ['scale', 'routing']);
    expect(
      restored.pendingQuestionContexts.map((context) => context.questionId),
      ['scale', 'routing'],
    );
    expect(
      restored.pendingQuestionContexts.every(
        (context) => context.project.isEmpty && context.baseRevision.isEmpty,
      ),
      isTrue,
    );
  });
}
