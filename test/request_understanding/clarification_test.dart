import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/models/design_brief.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/services/clarification_service.dart';

void main() {
  test('explicit future routing memory keeps its venue scope', () {
    expect(
      ClarificationService.rememberedRoutingRequest(
        'please remember OSPF for future office labs.',
      ),
      (protocol: 'ospf', venue: 'office'),
    );
    expect(
      ClarificationService.rememberedRoutingRequest(
        'remember to use EIGRP for future home lab',
      ),
      (protocol: 'eigrp', venue: 'home'),
    );
    expect(
      ClarificationService.rememberedRoutingRequest(
        'Should I remember OSPF for future office labs?',
      ),
      isNull,
    );
    expect(
      ClarificationService.rememberedRoutingRequest(
        'Add a switch and remember OSPF for future office labs',
      ),
      isNull,
    );
  });

  test('scale answers reject VLAN IDs, models, ports and prefixes', () {
    for (final value in ['VLAN 40', '2911', 'g0/1', '/24']) {
      expect(
        ClarificationService.resolveAnswer(
          ClarificationService.scaleQuestion,
          value,
        ),
        isNull,
        reason: value,
      );
    }
  });

  test('scale accepts one quantity in English or Arabic digits', () {
    for (final value in ['about 40 users', '٤٠ جهاز']) {
      expect(
        ClarificationService.resolveAnswer(
          ClarificationService.scaleQuestion,
          value,
        )?.value,
        '40',
        reason: value,
      );
    }
  });

  test('user load is distinct from physical device inventory', () {
    final load = ClarificationService.resolveAnswer(
      ClarificationService.scaleQuestion,
      '40 users',
    )!;
    final devices = ClarificationService.resolveAnswer(
      ClarificationService.scaleQuestion,
      '40 devices',
    )!;

    expect(load.quantityKind, QuantityKind.userLoad);
    expect(devices.quantityKind, QuantityKind.deviceInventory);
    expect(
      const DesignBrief().withFact(DesignBrief.scale, load).ready,
      isFalse,
      reason: 'a user-load answer does not set the required device count',
    );
    expect(
      const DesignBrief().withFact(DesignBrief.scale, load).missing,
      contains(DesignBrief.scale),
    );
    expect(
      BriefFact.fromJson(load.toJson()).quantityKind,
      QuantityKind.userLoad,
    );
  });

  test('ambiguous routing alternatives need another answer', () {
    expect(
      ClarificationService.resolveAnswer(
        ClarificationService.routingQuestion,
        'OSPF or EIGRP',
      ),
      isNull,
    );
    expect(
      ClarificationService.resolveAnswer(
        ClarificationService.routingQuestion,
        'do not use OSPF, use EIGRP',
      )?.value,
      'eigrp',
    );
  });

  test('one message resolves all clearly answered pending questions', () {
    final answers = ClarificationService.resolveAnswers(
      questions: const [
        ClarificationService.scaleQuestion,
        ClarificationService.routingQuestion,
        ClarificationService.segmentationQuestion,
      ],
      answerText: '40 devices, OSPF, one flat LAN',
    );

    expect(answers.keys, containsAll(['scale', 'routing', 'segmentation']));
    expect(answers['scale']?.value, '40');
    expect(answers['routing']?.value, 'ospf');
    expect(answers['segmentation']?.value, 'none');
  });

  test('an explicit inventory does not trigger a generic scale question', () {
    const instruction = 'R1, SW1, PC1, PC2';
    expect(NetworkIntent.namesAnyDeviceIn(instruction.toLowerCase()), isTrue);
    final plan = NetworkIntent.parseSimple('office', instruction);
    final questions = ClarificationService.neededFor(
      brief: const DesignBrief(),
      plan: plan,
      rememberedQuestionIds: const {},
      instruction: instruction,
    );

    expect(questions.map((question) => question.id), isNot(contains('scale')));
  });

  test(
    'a specified single-router topology needs no generic brief questions',
    () {
      const instruction = 'R1, SW1, PC1 and PC2; one LAN, no dynamic routing';
      final plan = NetworkIntent.parseSimple('office', instruction);
      final questions = ClarificationService.neededFor(
        brief: const DesignBrief(),
        plan: plan,
        rememberedQuestionIds: const {},
        instruction: instruction,
      );

      expect(questions, isEmpty);
    },
  );

  test('a switch-only topology gets no router or routing question', () {
    const instruction = '2 switches, 8 PCs, one flat LAN, no router';
    final plan = NetworkIntent.parseSimple('office', instruction);
    final questions = ClarificationService.neededFor(
      brief: const DesignBrief(),
      plan: plan,
      rememberedQuestionIds: const {},
      instruction: instruction,
    );

    expect(plan.nodes.where((node) => node.type == 'router'), isEmpty);
    expect(questions, isEmpty);
  });

  test('router and switch counts alone leave client capacity open', () {
    const instruction = '2 routers and 4 switches';
    final plan = NetworkIntent.parseSimple('office', instruction);
    final questions = ClarificationService.neededFor(
      brief: const DesignBrief(),
      plan: plan,
      rememberedQuestionIds: const {},
      instruction: instruction,
    );

    expect(questions.map((question) => question.id), contains('scale'));
  });

  test('a scale answer sets the total instead of adding that total', () {
    const original = '1 router, 1 switch, 10 PCs';
    final plan = NetworkIntent.parseSimple('office', original);
    final resized = ClarificationService.reconcilePlanWithFact(
      plan: plan,
      questionId: DesignBrief.scale,
      fact: const BriefFact(
        value: '40',
        display: '40 devices',
        quantityKind: QuantityKind.deviceInventory,
      ),
      previousBrief: original,
    );

    expect(resized?.nodes.where((node) => node.type == 'pc').length, 40);
    expect(resized?.nodes.where((node) => node.type == 'router').length, 1);
    expect(resized?.nodes.where((node) => node.type == 'switch').length, 1);
  });

  test('a later scale answer preserves the previously chosen routing', () {
    const original = '2 routers, 2 switches, 10 PCs';
    final plan = NetworkIntent.parseSimple(
      'office',
      original,
    ).copyWith(routing: 'ospf');
    final resized = ClarificationService.reconcilePlanWithFact(
      plan: plan,
      questionId: DesignBrief.scale,
      fact: const BriefFact(
        value: '40',
        display: '40 devices',
        quantityKind: QuantityKind.deviceInventory,
      ),
      previousBrief: original,
    );

    expect(resized?.nodes.where((node) => node.type == 'pc').length, 40);
    expect(resized?.routing, 'ospf');
  });

  test('a user-load answer leaves the physical inventory unchanged', () {
    const original = '1 router, 1 switch, 10 PCs';
    final plan = NetworkIntent.parseSimple('office', original);
    final answered = ClarificationService.resolveAnswer(
      ClarificationService.scaleQuestion,
      '40 users',
    )!;
    final result = ClarificationService.reconcilePlanWithFact(
      plan: plan,
      questionId: DesignBrief.scale,
      fact: answered,
      previousBrief: original,
    );

    expect(result?.nodes.where((node) => node.type == 'pc').length, 10);
    final questions = ClarificationService.neededFor(
      brief: const DesignBrief().withFact(DesignBrief.scale, answered),
      plan: result,
      rememberedQuestionIds: const {},
    );
    expect(questions.map((question) => question.id), contains('scale'));
  });

  test('a user-load request asks how many devices the plan should include', () {
    const instruction = 'This fixed network must serve 40 users';
    final plan = NetworkIntent.parseSimple(
      'office',
      '1 router, 1 switch, 10 PCs',
    );
    final load = ClarificationService.resolveAnswer(
      ClarificationService.scaleQuestion,
      '40 users',
    )!;
    final brief = const DesignBrief().withFact(DesignBrief.scale, load);
    final questions = ClarificationService.neededFor(
      brief: brief,
      plan: plan,
      rememberedQuestionIds: const {},
      instruction: instruction,
    );

    expect(questions.map((question) => question.id), contains('scale'));
    expect(questions.first.question, contains('PCs or end-user devices'));
  });
}
