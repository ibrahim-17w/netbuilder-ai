import '../models/chat_message.dart';
import '../models/environment_profile.dart';
import '../models/network_intent.dart';
import 'advisor_service.dart';
import 'casual_english.dart';
import 'chat_capabilities.dart';
import 'clarification_service.dart';
import 'conversation_memory.dart';
import 'learned_answers_service.dart';
import 'offline_knowledge.dart';
import 'plan_config_composer.dart';
import 'plan_repair_service.dart';
import 'scope_gate.dart';
import 'topology_reasoner.dart';
import 'troubleshoot_flows.dart';
import 'validator_service.dart';

/// A conversational reply produced without any model.
class AssistantReply {
  final String text;

  /// What the assistant still needs to know. Kept structured as well as in
  /// [text] so the chat can offer them as tappable answers.
  final List<String> questions;

  /// Short messages the user can send with one tap - the conversational
  /// equivalent of a follow-up. Every one of them is something the offline
  /// path can actually act on, so a tap is never a dead end.
  final List<String> quickReplies;

  /// build | advice | howto | change | fix | vague | greeting | bye | recall
  /// | ack | confirm | deny | identity | capability | missing | offtopic
  final String intent;

  /// The plan as it stands AFTER this answer, when the answer repaired it.
  ///
  /// "fix the plan" changes the plan rather than describing it, so the caller
  /// has to store what came back: without this the repaired plan would be
  /// reported and then thrown away, and the next turn would find the same
  /// findings in place.
  final NetworkIntent? repairedPlan;

  /// The troubleshooting-flow state to persist after this turn, or null to
  /// leave the caller's state untouched. An EMPTY map ends (and clears) the
  /// flow; a non-empty one is the live state to pass back as [reply]'s
  /// `activeFlow` on the next turn. See [TroubleshootFlows] - the state is
  /// JSON-serializable primitives, so it survives a conversation reopen.
  final Map<String, dynamic>? flowState;

  /// What the repair changed, in machine form (see [RepairFix]).
  ///
  /// The caller parks these against [repairedPlan] until a build of that plan
  /// verifies; nothing reads them before then. Carrying them here is what lets
  /// the learning loop key off the fix itself rather than off the sentence
  /// written for the user, which names this plan's addresses and ports.
  final List<RepairFix> repairedFixes;

  /// The structured advice answer behind an `intent: 'advice'` reply.
  ///
  /// [text] already renders it (via [AdviceAnswer.toText]); this carries the
  /// parts, so the chat can show a real advice card - recommendation
  /// highlighted, options laid out, "Plan this" wired to [AdviceAnswer
  /// .planBrief] - instead of asking a markdown table to be a button.
  final AdviceAnswer? advice;

  const AssistantReply(
    this.text, {
    this.questions = const [],
    this.quickReplies = const [],
    this.intent = 'build',
    this.repairedPlan,
    this.flowState,
    this.repairedFixes = const [],
    this.advice,
  });
}

/// The keyless assistant: a normal, advisory answer instead of a plan dump or
/// a "could not reach the model" error.
///
/// It is deterministic on purpose. It recognises what the user is asking for,
/// answers questions from a small Cisco/Packet-Tracer knowledge base, plans a
/// build request, and - when the request is too vague - asks for what it
/// needs. It never invents credentials and never claims anything was built or
/// verified.
class OfflineAssistantService {
  const OfflineAssistantService._();

  static final RegExp _arabicScript = RegExp(r'[\u0600-\u06FF]');

  static final RegExp _whitespace = RegExp(r'\s+');

  static AssistantReply reply({
    required String rawText,
    required String normalized,
    required String target,
    NetworkIntent? plan,
    NetworkIntent? previousPlan,
    List<String> suggestions = const [],
    String modelError = '',
    List<ChatMessage> history = const [],
    bool privateMode = false,
    // Files this conversation produced, for "show saved networks" - the
    // chat owns the artifact list; the answer only reports what is real.
    List<({String name, String note})> knownArtifacts = const [],
    // A live troubleshooting flow ({'flow', 'step', 'data'}) from
    // [SessionState.flowState]: when one is active, this turn is answered
    // INSIDE the flow (the user is tapping diagnostic options), and the
    // reply carries the next state back in AssistantReply.flowState.
    Map<String, dynamic>? activeFlow,
    // The answer this exact question earned from the keyed model before
    // (see [LearnedAnswers]): replayed verbatim, offline, before any other
    // branch - "same question, same answer" is the promise.
    LearnedAnswer? learnedAnswer,
    // The remembered environment (see [EnvironmentProfile]): fills in the
    // venue/scale/budget the message leaves unsaid, so advice written for a
    // remembered office does not fall back to generic.
    EnvironmentProfile? environmentProfile,
    // Critical gaps the chat wants clarified before a plan is committed
    // (see [ClarificationService]). When non-empty and the turn is
    // build-shaped, the answer asks these instead of describing a plan.
    List<ClarificationQuestion> clarifyingQuestions = const [],
    // The scale the design brief already settled in this conversation. The
    // advisor uses it only for advice (and for the one-tap plan that advice
    // offers) - it never touches the plan - but without it a follow-up like
    // "what firewall do we need for an office with guests?" advises at no
    // scale at all, and the plan it then builds carries zero hosts.
    int? briefScale,
  }) {
    // MEMORY: the earlier turns of this conversation are the difference
    // between a useful answer and a generic one. The offline path has no
    // model, so it reads them directly.
    final asks = ConversationMemory.userAsks(history);
    final originalAsk = asks.isEmpty ? '' : asks.first;
    final t = normalized.trim().toLowerCase();
    // Deterministic variety: the same question gets the same words, but two
    // consecutive turns do not get the same opener.
    final seed = history.length;
    // The user's language: when the message carries Arabic script, answers
    // keep their English technical content (device commands ARE English) but
    // are framed in Arabic, so a mixed "كيف أعمل ssh" conversation is
    // answered, not ignored.
    final arabic =
        _arabicScript.hasMatch(rawText.isEmpty ? normalized : rawText);

    // The answer starts with its CONTENT. Which brain produced it - the
    // planner, a model, a learned answer - is the app's state, shown once
    // in the top bar's AI pill, not a line repeated under every message.
    const opening = '';

    if (t.isEmpty) {
      return AssistantReply(
        _join(opening, arabic ? _vagueAnswerAr : _vagueAnswer(originalAsk)),
        questions: _vagueQuestions,
        quickReplies: _exampleReplies,
        intent: 'vague',
      );
    }
    if (_isRecall(t)) {
      return AssistantReply(
        _join(opening, _recallAnswer(asks, normalized, plan)),
        quickReplies: _nextStepsFor(plan),
        intent: 'recall',
      );
    }
    if (_isGreeting(t)) {
      return AssistantReply(
        _join(
          opening,
          arabic
              ? _pick(const [
                  'مرحباً! أنا مساعد NetBuilder وأعمل دون اتصال - لا حاجة إلى مفتاح API، ولا شيء يخرج من جهازك. أخبرني ماذا تريد أن تبني (مثلاً "2 routers, 1 switch and 4 PCs with OSPF") أو اسألني عن الشبكات.',
                  'أهلاً بك! المساعد يعمل دون اتصال - بلا مفتاح وبلا انتظار. صِف الشبكة التي تريدها أو اسألني عن أي تقنية (الأوامر بالإنجليزية).',
                ], seed)
              : _pick(const [
                  'Hi! I am the NetBuilder assistant and I am running offline - no '
                      'API key needed, and nothing you type leaves this device. Tell '
                      'me what to build (for example "2 routers, 1 switch and 4 PCs '
                      'with OSPF"), or ask me a networking question and I will '
                      'answer with advice.',
                  'Hello! Offline assistant here - no key, nothing leaves this '
                      'device, and no waiting on a model. Describe the lab you want '
                      'and I will plan it, or ask me a networking question.',
                ], seed),
        ),
        quickReplies: _exampleReplies,
        intent: 'greeting',
      );
    }
    // BYE: a farewell is a turn, not a request. Answered warmly and honestly
    // - everything the conversation produced stays on this device - with the
    // example briefs as the way back in. Read BEFORE the yes/no branch,
    // because "later" is a goodbye here, not a "no".
    if (_isBye(t)) {
      return AssistantReply(
        _join(
          opening,
          arabic
              ? _pick(const [
                  'مع السلامة! كل شيء محفوظ على جهازك - عُد في أي وقت وسنكمل '
                      'من حيث توقفنا.',
                  'إلى اللقاء! لا يخرج شيء مما بنيناه من جهازك - وأنا هنا '
                      'عندما تعود.',
                ], seed)
              : _pick(const [
                  'Take care! Everything stays on this device - come back any '
                      'time and we will pick up right where we left off.',
                  'See you! The plans and .pkt files are all saved on this '
                      'device - nothing leaves it, and I am here when you '
                      'are back.',
                ], seed),
        ),
        quickReplies: _exampleReplies,
        intent: 'bye',
      );
    }
    // A thank-you or an "ok" is a real turn in a conversation. Answering it
    // with a plan dump reads like a form; answering it like a person, with the
    // plan still in reach, is what makes the offline chat feel continuous.
    if (_isAck(t)) {
      return AssistantReply(
        _join(
          opening,
          arabic ? _ackAnswerAr(plan, seed) : _ackAnswer(plan, seed),
        ),
        quickReplies: _nextStepsFor(plan),
        intent: 'ack',
      );
    }
    if (_isYes(t)) {
      final blocked = plan == null ? const <ValidationIssue>[] : _blocking(plan, target);
      return AssistantReply(
        _join(opening, _confirmAnswer(plan, suggestions, blocked)),
        quickReplies: _nextStepsFor(plan, blocked: blocked),
        intent: 'confirm',
      );
    }
    if (_isNo(t)) {
      return AssistantReply(
        _join(opening, _denyAnswer(plan)),
        intent: 'deny',
      );
    }
    // FLOW CONTINUATION: an active troubleshooting flow owns this turn. The
    // user is answering a diagnostic question ("what does the port show?"),
    // so the flow's next step - or its fix - IS the answer. An explicit
    // exit ("never mind") drops the ladder instead of asking it a
    // question. Anything the flow cannot match re-asks with a hint, which
    // is the engine's own fail-closed behavior.
    if (activeFlow != null && activeFlow.isNotEmpty) {
      if (_flowExit.hasMatch(t)) {
        return AssistantReply(
          _join(
            opening,
            'Ladder dropped - say the symptom again any time (for example '
            '"PC1 cannot ping PC2") and I will start it fresh.',
          ),
          quickReplies: _exampleReplies,
          intent: 'troubleshoot',
          flowState: const {},
        );
      }
      final turn = TroubleshootFlowEngine.advance(activeFlow, t);
      return AssistantReply(
        _join(opening, (turn.fix ?? turn.prompt)),
        quickReplies: turn.done
            ? _nextStepsFor(plan)
            : [for (final o in turn.options) o.label],
        intent: 'troubleshoot',
        flowState: turn.done ? const {} : turn.state,
      );
    }
    // LEARNED ANSWER: this exact question was answered by the keyed model
    // before and the answer passed the capture checks, so the same
    // question asked offline gets the same answer - verbatim, with a
    // provenance line. Exact-key only on purpose: the question the user
    // actually asked gets the answer they were actually given, while
    // paraphrases stay with the curated corpus, which is the better
    // answer for wording it has never seen.
    if (learnedAnswer != null && learnedAnswer.answer.trim().isNotEmpty) {
      return AssistantReply(
        _join(opening, learnedAnswer.answer),
        quickReplies: _nextStepsFor(plan),
        intent: 'learned',
      );
    }
    // IDENTITY: "who are you", "what can you do", "how are you" - questions
    // about the assistant itself. They used to fall through to the scope
    // gate or, worse, to the missing-coverage line - an odd answer to "who
    // are you" from an assistant that plans whole labs. The guard below is
    // what keeps this from swallowing real work: a message that carries
    // networking vocabulary is a network question wearing an identity
    // opener ("what can you do about the OSPF adjacency"), the same way a
    // greeting that names a lab is a build request wearing a hello.
    final identity = _identityKind(t);
    if (identity != null) {
      return AssistantReply(
        _join(
          opening,
          arabic
              ? _identityAnswerAr(identity, seed)
              : _identityAnswer(identity, seed),
        ),
        quickReplies: _identityReplies,
        intent: 'identity',
      );
    }
    // SCOPE: this assistant is networking-only. A coding request, homework
    // or general chit-chat gets the one-line decline - never a plan, never a
    // guess. The gate is conservative: anything carrying networking
    // vocabulary passes, so a real network question is never refused.
    if (ScopeGate.isOffTopic(rawText.isNotEmpty ? rawText : normalized)) {
      return AssistantReply(
        _join(opening, ScopeGate.decline),
        quickReplies: const [
          'Plan a network for 10 employees on two floors',
          'What is better, OSPF or static routing?',
        ],
        intent: 'offtopic',
      );
    }
    // REACHABILITY: "why can't PC1 ping PC2" is answered by WALKING THE
    // PLAN - cabled path, addressing, subnet, gateway, duplicates, routing,
    // cable sanity - and reporting the first blocking rung with its fix.
    // This is the app reasoning over its own model, not matching text, so
    // it runs before the advice reader and the knowledge table (whose
    // generic "cannot ping" ladder would otherwise eat the question).
    // Needs a plan: without one there is no topology to reason about, and
    // the question falls through to the generic answers.
    if (plan != null) {
      final question = ReachabilityQuestion.parseQuestion(t, plan);
      if (question.question != null) {
        final verdict = TopologyReasoner.explain(
          plan: plan,
          from: question.question!.from,
          to: question.question!.to,
          target: target,
        );
        return AssistantReply(
          _join(opening, verdict.toText()),
          quickReplies: verdict.quickReplies,
          intent: 'reachability',
        );
      }
    }
    // FLOW OPENER: an OPEN symptom ("PC cannot ping anything", "no
    // internet") opens an interactive diagnostic ladder instead of a
    // static answer - the assistant asks what the verification command
    // shows and the user taps the reply. Deliberately AFTER the
    // reachability reasoner (a named device pair is reasoned over the
    // plan, not turned into a questionnaire) and after the named-target
    // guard inside matchStart (a specific "cannot ping the gateway" gets
    // the corpus ladder, which answers it directly). Runs before the
    // knowledge table: the ladder IS the deeper version of that answer.
    final flowId = TroubleshootFlows.matchStart(t);
    if (flowId != null) {
      final turn = TroubleshootFlows.open(flowId)!;
      return AssistantReply(
        _join(opening, turn.prompt),
        quickReplies: [for (final o in turn.options) o.label],
        intent: 'troubleshoot',
        flowState: turn.state,
      );
    }
    // ADVICE: "what router should I use in this case?", "how many access
    // points for 50 users?", "fiber or copper?", "review my design".
    // These used to fall through to the plan dump (a router was named, so
    // the missing-coverage reply refused them) or to "I need a bit more to
    // go on". The advisor leads with a recommendation, then the options and
    // their trade-offs, grounds them in what the user said and in the plan
    // on the table - and never touches the plan.
    //
    // It runs BEFORE the capability table: "review my design" is advice,
    // while "review the plan" keeps routing to the plan-suggestions
    // capability (the advisor does not claim it).
    final advice = AdvisorService.advise(
      // The normalized text, not the raw one: a typo'd question ("what
      // routr for 30 staff?") must reach the advisor's topic words, and
      // CasualEnglish already fixed it on the planner path.
      t.isEmpty ? rawText : t,
      plan: plan,
      target: target,
      environmentProfile: environmentProfile,
      briefScale: briefScale,
    );
    if (advice != null) {
      return AssistantReply(
        _join(
          opening,
          '${arabic ? '$_arabicLead\n\n' : ''}'
          '${_continuity(plan, t, history)}${advice.toText()}',
        ),
        questions: advice.questions,
        quickReplies: advice.quickReplies.isNotEmpty
            ? advice.quickReplies
            : _nextStepsFor(plan),
        intent: 'advice',
        advice: advice,
      );
    }
    // APP CAPABILITIES: "validate the plan", "any duplicate IPs", "what
    // should I improve" are things this app really does - they are Action
    // Hub buttons, and the same services behind those buttons answer here.
    // The checks are read-only, run on the plan that is actually open, and
    // say so; anything that changes a device or a file keeps its existing
    // approval-gated path instead of running from the chat.
    final capability = ChatCapabilities.match(
      rawText.trim().isEmpty ? t : rawText.toLowerCase(),
    );
    if (capability != null) {
      return AssistantReply(
        _join(
          opening,
          ChatCapabilities.answer(
            capability,
            plan: plan,
            target: target,
            knownArtifacts: knownArtifacts,
          ),
        ),
        quickReplies: _nextStepsFor(plan),
        intent: 'capability',
      );
    }
    // A one- or two-word opener with no device in it ("help", "hmm",
    // "what") must not be planned as if it were a brief: the parser would
    // invent a router and a switch. Ask instead.
    //
    // A short message that names a real topic ("and vlans?", "why stp?") is
    // not an opener - it is a follow-up, and it gets an answer.
    final words = t.split(_whitespace).where((w) => w.isNotEmpty).toList();
    final hasDeviceWord = _deviceWords.hasMatch(t);
    final concept = _concept(t);
    if (words.length <= 2 &&
        !hasDeviceWord &&
        concept == null &&
        OfflineKnowledge.answerFor(t) == null) {
      return AssistantReply(
        _join(opening, _vagueAnswer(originalAsk)),
        questions: _vagueQuestions,
        quickReplies: _exampleReplies,
        intent: 'vague',
      );
    }
    // A question about the conversation, however it is phrased: "what were we
    // doing", "do you still remember my first ask", "which file did you make".
    if (_isRecall(t) && asks.isNotEmpty) {
      return AssistantReply(
        _join(opening, _recallAnswer(asks, normalized, plan)),
        quickReplies: _nextStepsFor(plan),
        intent: 'recall',
      );
    }
    if (_isChange(t)) {
      // A change is only worth claiming if it landed. The plan is compared with
      // the one before this turn, so "nothing changed" is said out loud instead
      // of leaving the user to build a file and find out.
      final delta = plan == null
          ? ''
          : NetworkIntent.planChangeSummary(previousPlan, plan);
      final hasLab = plan != null && plan.nodes.isNotEmpty;
      // A change that landed on a plan the build will refuse has still not
      // produced anything usable, so the closing line is chosen from the same
      // findings the card shows rather than always advertising the build.
      final blocked = hasLab ? _blocking(plan, target) : const <ValidationIssue>[];
      final buildLine = blocked.isEmpty
          ? 'Press "Build the .pkt" below and I compile the whole lab, not '
              'just the change - offline, with no Packet Tracer.'
          : 'The Build card below is withheld: this plan still has '
              '${blocked.length} finding(s) that would be baked into the .pkt '
              '(first: ${blocked.first.message}). Fix that and the build '
              'unlocks.';
      final body = StringBuffer()..writeln(_describeChange(t));
      if (hasLab && delta.isNotEmpty) {
        body
          ..writeln()
          ..writeln('That updates the lab you had: $delta.')
          ..writeln()
          ..writeln('The lab now reads ${_labLine(plan)}. $buildLine');
      } else if (hasLab) {
        body
          ..writeln()
          ..writeln(
            'As far as the plan goes nothing changed - it still reads '
            '${_labLine(plan)}. If that was meant to add or alter something, '
            'say it as a request ("add an AAA server with 3 users", "use '
            'OSPF") and I will plan it in.',
          );
      }
      body
        ..writeln()
        ..writeln(
          'To make it stick for future plans, save it as a rule (Memory, or '
          'the "Teach a correction" box) - for example "always use a 4331 '
          'router" or "LANs in 10.20.0.0/24". Saved rules are applied to the '
          'next plan automatically.',
        );
      return AssistantReply(
        _join(opening, body.toString().trimRight()),
        quickReplies: _nextStepsFor(plan, blocked: blocked),
        intent: 'change',
      );
    }
    // REPAIR: "fix the plan", "fix these", "fix it", "solve these findings".
    // This used to be answered by the build branch below - the same plan dump,
    // with the same finding the user had just been told to clear - so saying
    // "fix the plan" in the chat did nothing at all. The repair pass is
    // deterministic and offline, so it can be run here rather than described.
    if (_isFix(t)) {
      return fixPlan(
        plan: plan,
        target: target,
        suggestions: suggestions,
        opening: opening,
        // "fix every finding then build" is one request, not two: the reply
        // must not ask for the click the user already asked for.
        andBuild: asksToBuildAfterRepair(rawText),
      );
    }
    // TWO INTENTS, ONE TURN: "2 routers and 4 switches, what is the best
    // colour for the cable" describes a lab AND asks about something else.
    // Answering only the question throws the brief away; answering only the
    // brief answers something nobody asked. [mixed] marks that this turn
    // carries both, and [briefNote] is the one line that carries the half of
    // it no branch below would otherwise speak. It only ever APPENDS - the
    // answer to the question is still the answer.
    //
    // A WH-question is read anywhere in the sentence, because that is where
    // the second intent actually sits ("..., what is the best ..."), while a
    // bare "..." is only a question when the user wrote a "?".
    final wh = _whWord.hasMatch(t);
    final mixed =
        _deviceCount.hasMatch(t) &&
        (wh || _howtoShaped(t) || rawText.trim().endsWith('?'));
    final briefNote = mixed ? _briefNote(plan, clarifyingQuestions) : '';
    if (concept != null) {
      // PLAN-AWARE: with a lab on the table the generic explainer is
      // followed by the section composed from THIS plan - their routers,
      // their subnets - and the "tell me the lab" tail is dropped, because
      // the lab is known and the commands below are already specific.
      final grounded =
          _groundedSection(concept, plan, target);
      return AssistantReply(
        _join(
          opening,
          '${arabic ? '$_arabicLead\n\n' : ''}${_continuity(plan, t, history)}'
          '${_conceptAnswer(concept)}'
          '${grounded == null ? '\n\nIf you tell me the lab you are building '
              'I will turn this into a plan and give you the exact steps.'
              : '\n\n$grounded'}'
          '${briefNote.isEmpty ? '' : '\n\n$briefNote'}',
        ),
        quickReplies: _nextStepsFor(plan),
        intent: 'howto',
      );
    }
    // OFFLINE KNOWLEDGE: the answer battery. Concepts, configuration steps,
    // verification and the classic faults - plus real arithmetic for subnet
    // questions - answered deterministically, with no model and no API key.
    // A build request never reaches this table (device counts were already
    // routed to the planner, and build asks return nothing here).
    final knowledge = OfflineKnowledge.answerFor(t);
    if (knowledge != null) {
      // PLAN-AWARE, knowledge path: the corpus entry answers the topic
      // generically; when the text maps to a composable topic and a plan
      // stands, the lab-specific section follows it.
      final grounded = _groundedSection(
        PlanConfigComposer.topicFor(t),
        plan,
        target,
      );
      return AssistantReply(
        _join(
          opening,
          '${arabic ? '$_arabicLead\n\n' : ''}${_continuity(plan, t, history)}$knowledge'
          '${grounded == null ? '\n\nIf you tell me the lab you are building '
              'I will turn this into a plan and give you the exact steps.'
              : '\n\n$grounded'}'
          '${briefNote.isEmpty ? '' : '\n\n$briefNote'}',
        ),
        quickReplies: _nextStepsFor(plan),
        intent: 'howto',
      );
    }
    // BARE-TOPIC RESCUE: "how do I configure ospf" has no concept hook and
    // no corpus entry, so without a plan it falls to missing coverage - but
    // WITH a plan the composed lab-specific section IS the answer, and a
    // better one than any generic text. Fail-closed both ways: no plan
    // means the normal near-miss reply, and an unsupported topic means
    // null here exactly as before.
    final rescueTopic = PlanConfigComposer.topicFor(t);
    if (rescueTopic != null &&
        plan != null &&
        // The same guard the concept reader applies: a device COUNT in a
        // non-question ("...OSPF area 0, 15 PCs") is a build brief, not a
        // config question - the build answer must keep it. A device count in
        // a QUESTION is the other way round: the question is the ask, and
        // [mixed] lets the composed lab answer it instead of being dropped
        // back to the plan dump.
        (!_deviceCount.hasMatch(t) || _howtoShaped(t) || mixed)) {
      final grounded = _groundedSection(rescueTopic, plan, target);
      if (grounded != null) {
        return AssistantReply(
          _join(
            opening,
            '${arabic ? '$_arabicLead\n\n' : ''}'
            '${_continuity(plan, t, history)}$grounded'
            '${briefNote.isEmpty ? '' : '\n\n$briefNote'}',
          ),
          quickReplies: _nextStepsFor(plan),
          intent: 'howto',
        );
      }
    }
    // NOT COVERED: a real question this material does not know. Say exactly
    // that - a guess dressed as fact is worse than an honest gap - but first
    // offer the ground that IS covered and sits nearest to the question.
    // (A short opener still gets the "tell me what you want" reply below.)
    if (_openQuestion(
      t,
      words.length,
      hasPlan: plan != null && plan.nodes.isNotEmpty,
    )) {
      return _missingReply(
        t,
        arabic: arabic,
        opening: opening,
        plan: plan,
      );
    }
    if (plan != null && plan.nodes.isNotEmpty) {
      // ASK BEFORE PLAN: the brief has critical gaps and the chat supplied
      // the questions to ask. The plan-shaped parse still stands (so the
      // conversation keeps its context), but the answer asks instead of
      // dumping a plan with a build button - the user said they want a
      // network, not that they want THIS network yet.
      if (clarifyingQuestions.isNotEmpty) {
        return _clarifyReply(clarifyingQuestions, opening, arabic);
      }
      // TWO ASKS, ONE ANSWER, NEITHER ANSWERED: a counted WH-question whose
      // topic has no offline coverage used to fall through to the plan dump,
      // so the reply described the lab and never said a thing about what was
      // asked. Answer the gap honestly and then name the brief, instead of
      // putting a Build button under a question.
      //
      // A yes/no turn ("2 routers and 4 switches, is that enough?") stays on
      // the build path deliberately: there the plan IS the answer, and
      // trading it for "not in my offline material" would answer worse.
      if (mixed && wh) {
        final gap = _missingReply(t, arabic: arabic, opening: opening);
        final chips = <String>[
          ...gap.quickReplies,
          ..._nextStepsFor(plan, blocked: _blocking(plan, target)),
        ];
        return AssistantReply(
          _join(gap.text, briefNote),
          questions: gap.questions,
          quickReplies: [...{for (final c in chips) c}],
          intent: gap.intent,
        );
      }
      return AssistantReply(
        _buildAnswer(
          plan,
          suggestions,
          originalAsk,
          target: target,
          opening: opening,
          previousPlan: previousPlan,
        ),
        // The quick replies are the same gate the card uses: offering "Build
        // the .pkt" for a plan the card is going to refuse is the reported
        // "press build, it says it did not build" dead end.
        quickReplies: _nextStepsFor(
          plan,
          building: true,
          blocked: _blocking(plan, target),
        ),
        intent: 'build',
      );
    }
    return AssistantReply(
      _join(opening, arabic ? _vagueAnswerAr : _vagueAnswer(originalAsk)),
      questions: _vagueQuestions,
      quickReplies: _exampleReplies,
      intent: 'vague',
    );
  }

  // --- conversational moves -----------------------------------------------

  /// The half of a two-intent turn that no answer branch speaks: the lab
  /// the user described while asking their question.
  ///
  /// Two states, two different things to say. A brief that is still missing
  /// critical scale is not a lab yet, so the note carries the questions and
  /// says it is not planned; a brief that is ready says so and names the
  /// words that build it. Either way it is ONE line at the end of a real
  /// answer - the question stays the point of the reply.
  ///
  /// The lab is named with [_labLine], the same rendering the ack, change and
  /// "nothing changed" replies use, so a lab reads one way wherever the chat
  /// mentions it.
  static String _briefNote(
    NetworkIntent? plan,
    List<ClarificationQuestion> clarifying,
  ) {
    if (plan == null || plan.nodes.isEmpty) return '';
    final described = _labLine(plan);
    if (described.isEmpty) return '';
    if (clarifying.isNotEmpty) {
      final asks = [
        for (final q in clarifying)
          if (q.question.trim().isNotEmpty) q.question.trim(),
      ];
      return asks.isEmpty
          ? 'You are also describing a lab with $described. It is not '
              'planned yet - tell me the rest and I will plan it.'
          : 'You are also describing a lab with $described, which I have not '
              'planned yet: ${asks.join(' ')}';
    }
    return 'You are also describing a lab with $described - say "build the '
        '.pkt" and I will compile it offline.';
  }

  /// The ask-before-plan reply: the questions, the way out ("just build
  /// it"), and quick replies that are the answers themselves. The plan
  /// already parsed - it just is not being committed in this reply.
  static AssistantReply _clarifyReply(
    List<ClarificationQuestion> questions,
    String opening,
    bool arabic,
  ) {
    final b = StringBuffer();
    if (opening.isNotEmpty) b.writeln('$opening\n\n');
    b
      ..writeln(
        questions.length == 1
            ? '**One quick thing before I plan this:**'
            : '**Two quick things before I plan this:**',
      )
      ..writeln();
    for (var i = 0; i < questions.length; i++) {
      b.writeln('${i + 1}. ${questions[i].question}');
    }
    b
      ..writeln()
      ..writeln(
        'Tap an answer, or say "just build it" and I will use safe '
        'defaults for what is still open. Nothing is compiled until you '
        'say so.',
      );
    return AssistantReply(
      b.toString().trim(),
      // Chip order serves the composer's 4-chip cap: the FIRST question's
      // answers, then the way out, then the rest. The second question is
      // fully readable in the text and becomes the next turn's chips once
      // the first is answered - the ack loop carries the conversation.
      quickReplies: [
        if (questions.isNotEmpty) ...questions.first.quickReplies,
        'Just build it with defaults',
        for (final q in questions.skip(1)) ...q.quickReplies,
      ],
      intent: 'clarify',
    );
  }

  /// Openers that are answered rather than planned - a full plan dump in reply
  /// to "thanks" is how a conversation turns into a form.
  static const List<String> _exampleReplies = [
    '2 routers, 1 switch and 4 PCs with OSPF',
    'A small office with guest wifi and port security',
    'Connect two routers over a serial WAN',
  ];

  static final RegExp _ackPattern = RegExp(
    r'^(thanks|thank you|thx|ty|ok|okay|k|cool|nice|great|perfect|got it|'
    r'understood|sounds good|good|alright|awesome|will do|that works|'
    r'works for me|that.s fine|good job|lovely|done|'
    r'شكرا|شكرًا|شكراً|تسلم|تمام|طيب|ماشي|اوكي|أوكي|حسنا|حسناً|أوك|اوك|'
    r'يعطيك العافية)[.!؟]*$',
  );

  static bool _isAck(String t) => _ackPattern.hasMatch(t);

  /// "yes, do that", "yeah go ahead", "sure, build it" - agreement with an
  /// offer, which people rarely type as a bare "yes".
  static final RegExp _yesPattern = RegExp(
    r'^(yes|yeah|yep|yup|sure|do it|go ahead|go on|please do|please|of '
    r'course|correct|right|y|ok|okay|alright|absolutely|definitely|'
    r'(yes|yeah|sure|ok|okay)[,!.]?\s+(please\s+)?(do|go|build|make|create|'
    r'run|start|apply|edit|write|save)\b.*|'
    r'(go ahead|do it|build it|make it|run it|try it|please do|sounds good)'
    r'[.!]*$)',
  );

  static bool _isYes(String t) => _yesPattern.hasMatch(t);

  static final RegExp _noPattern = RegExp(
    r'^(no|nope|nah|not now|later|stop|dont|do not|no thanks|not yet|n)[.!]*$',
  );

  static bool _isNo(String t) => _noPattern.hasMatch(t);

  /// The findings that would be baked into the file, computed with the same
  /// validator call and the same target the build card uses, so this service
  /// and the card can never disagree about whether a plan is buildable.
  static List<ValidationIssue> _blocking(NetworkIntent plan, String target) {
    try {
      return ValidatorService.validate(plan, target: target)
          .where((i) => i.blocks)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// What a tap could say next. Only things the offline path can act on, so a
  /// tap never dead-ends.  A plan with findings that block the build does not
  /// offer the build: the chip would only lead back to a refusal.
  static List<String> _nextStepsFor(
    NetworkIntent? plan, {
    bool building = false,
    List<ValidationIssue> blocked = const [],
  }) {
    if (plan == null || plan.nodes.isEmpty) return const [];
    return [
      if (blocked.isEmpty) 'Build the .pkt',
      if (plan.routing != 'ospf') 'Use OSPF for routing',
      if (plan.routing == 'ospf') 'Use static routing instead',
    ];
  }

  static String _ackAnswer(NetworkIntent? plan, int seed) {
    if (plan != null && plan.nodes.isNotEmpty) {
      return _pick([
        'Any time. Your lab is still here - ${_labLine(plan)}. Tell me what to '
            'change, or say "build the .pkt" and I will compile it offline.',
        'No problem. ${_labLine(plan)} is still the plan I am holding, so we can '
            'pick up exactly there.',
      ], seed);
    }
    return _pick(const [
      'Any time. Whenever you are ready, describe the lab you want - for '
          'example "2 routers, 1 switch and 4 PCs with OSPF" - or ask me a '
          'networking question.',
      'Any time. Tell me the lab to build, or ask me about a technology, and I '
          'will take it from there.',
    ], seed);
  }

  /// The Arabic companion of [_ackAnswer]: the conversation stays continuous
  /// in the user's language.
  static String _ackAnswerAr(NetworkIntent? plan, int seed) {
    if (plan != null && plan.nodes.isNotEmpty) {
      return _pick([
        'على الرحب والسعة. الشبكة لا تزال محفوظة: ${_labLine(plan)}. '
            'قل لي ما تريد تغييره أو "build the .pkt" لأبني الملف دون اتصال.',
        'لا مشكلة. ${_labLine(plan)} لا تزال الخطة الحالية - نكمل من حيث '
            'توقفنا.',
      ], seed);
    }
    return _pick(const [
      'على الرحب والسعة. عندما تجهز، صِف الشبكة التي تريدها أو اسألني عن أي '
          'تقنية.',
      'على الرحب والسعة. أخبرني ماذا نبني، أو اسألني عن الشبكات، ونكمل من '
          'هناك.',
    ], seed);
  }

  static String _confirmAnswer(
    NetworkIntent? plan,
    List<String> suggestions, [
    List<ValidationIssue> blocked = const [],
  ]) {
    if (plan == null || plan.nodes.isEmpty) {
      return 'Great - what should I build? For example "2 routers, 1 switch and '
          '4 PCs with OSPF", or "a small office with guest wifi".';
    }
    final b = StringBuffer()..writeln('Then we go with ${_labLine(plan)}.');
    // A confirmation must not advertise a build the card is going to refuse:
    // "press Build" followed by "I did not build: 2 findings" is the dead end
    // that was reported. Say what is in the way and how to clear it instead.
    if (blocked.isNotEmpty) {
      b
        ..writeln()
        ..writeln(
          'I cannot build this one yet: it still has ${blocked.length} '
          'finding(s) that would be baked into the .pkt, so the Build card '
          'below is withheld rather than offered.',
        )
        ..writeln()
        ..writeln('First:');
      for (final issue in blocked.take(6)) {
        b.writeln('- [${issue.severity}] ${issue.message}');
      }
      if (blocked.length > 6) {
        b.writeln('- ... and ${blocked.length - 6} more.');
      }
      b
        ..writeln()
        ..writeln('Tell me what to change (or edit the plan in the network '
            'inspector) and I will re-plan and unlock the build. No API key '
            'is needed for any of it.');
      return b.toString().trimRight();
    }
    b
      ..writeln()
      ..writeln(
        'Press "Build the .pkt" below and I will compile it offline - no Packet '
        'Tracer and no API key.${suggestions.isEmpty ? '' : ' One thing worth '
            'fixing first: ${suggestions.first}'}',
      );
    return b.toString().trimRight();
  }

  static String _denyAnswer(NetworkIntent? plan) {
    final lab = plan == null || plan.nodes.isEmpty
        ? ''
        : ' The lab I am holding is ${_labLine(plan)}.';
    return 'Understood - nothing changes.$lab Tell me what to adjust: for '
        'example "use OSPF instead of static" or "make it 2 routers and 20 '
        'PCs".';
  }

  /// The answer to a repair request: run the deterministic repair pass over
  /// the standing plan, say exactly what changed, and - when the pass could
  /// not clear everything by itself - say which findings are left and that
  /// they need a decision from the user.
  ///
  /// Public because the chat runs this same path BEFORE it consults a model,
  /// so "fix the plan" behaves identically with and without a key.
  static AssistantReply fixPlan({
    required NetworkIntent? plan,
    required String target,
    List<String> suggestions = const [],
    String opening = '',

    /// The user asked for the build in the same message ("...then build").
    /// The wording then promises what happens next instead of asking for the
    /// click that was already given.
    bool andBuild = false,
  }) {
    if (plan == null || plan.nodes.isEmpty) {
      return AssistantReply(
        _join(
          opening,
          'There is no plan on the table to fix yet. Describe the lab - for '
              'example "2 routers, 2 switches and 15 PCs with OSPF" - and I '
              'will plan it and clear any finding that comes up.',
        ),
        quickReplies: _exampleReplies,
        intent: 'fix',
      );
    }
    final blocking = _blocking(plan, target);
    if (blocking.isEmpty) {
      // The plan is clean, so the only thing that can still be wrong is the
      // CARD: it was written for an earlier revision of this same network
      // (a build card whose button says "Fix the plan first" for a plan with
      // nothing wrong with it). The fresh card on this reply is what replaces
      // it, so say that instead of pretending to repair something.
      final b = StringBuffer()
        ..writeln(
          'Nothing in this plan blocks the build: the checks report no '
          'findings that would be baked into the .pkt (${_labLine(plan)}).',
        )
        ..writeln()
        ..writeln(
          andBuild
              ? 'Nothing to repair, so I am compiling it as it stands: the '
                    '.pkt is written offline, with no Packet Tracer and no API '
                    'key.'
              : 'If you pressed Build on an older card, that card was written '
                    'for an earlier version of this network. The card on this '
                    'reply is stamped with the plan that stands now - rev '
                    '${plan.revision} - so it builds what you can see.',
        );
      if (suggestions.isNotEmpty) {
        b
          ..writeln()
          ..writeln('Worth knowing:')
          ..writeln('- ${suggestions.first}');
      }
      return AssistantReply(
        _join(opening, b.toString().trimRight()),
        quickReplies: _nextStepsFor(plan),
        intent: 'fix',
        repairedPlan: plan,
      );
    }

    final repair = PlanRepairService.repair(plan, target: target);
    final b = StringBuffer();
    final remedy = _remedyFor(repair.remaining, plan: plan);
    if (repair.changes.isEmpty) {
      b
        ..writeln(
          andBuild
              ? 'I did not build it, and I cannot repair these from here - '
                    'each one needs a choice only you can make:'
              : 'I cannot repair these from here - each one needs a choice only '
                    'you can make:',
        )
        ..writeln();
      for (final issue in repair.remaining.take(6)) {
        b.writeln('- [${issue.severity}] ${issue.message}');
      }
      if (repair.remaining.length > 6) {
        b.writeln('- ... and ${repair.remaining.length - 6} more.');
      }
      if (remedy.isNotEmpty) {
        b
          ..writeln()
          ..writeln(remedy);
      }
      b
        ..writeln()
        ..writeln(
          'Tell me what to change - for example "move the branch onto '
          '192.168.20.0/24", "add another switch", or "use 192.168.30.0/24" '
          '- and I will plan it in and run the checks again.',
        );
    } else {
      b.writeln('Fixed ${repair.changes.length} thing(s):');
      for (final change in repair.changes) {
        b.writeln('- $change');
      }
      b.writeln();
      if (repair.remaining.isEmpty) {
        b.writeln(
          andBuild
              ? 'The plan is buildable now (${_labLine(repair.plan)}), so I am '
                    'compiling it into a .pkt - offline, no Packet Tracer and '
                    'no API key.'
              : 'The plan is buildable now (${_labLine(repair.plan)}). Press '
                    '"Build the .pkt" below and I compile the whole lab '
                    'offline - no Packet Tracer, no API key.',
        );
      } else {
        b
          ..writeln(
            andBuild
                ? 'I did not build it: these findings would be baked into the '
                      '.pkt and they need your call:'
                : 'These still block the build and need your call:',
          )
          ..writeln();
        for (final issue in repair.remaining.take(6)) {
          b.writeln('- [${issue.severity}] ${issue.message}');
        }
        if (remedy.isNotEmpty) {
          b
            ..writeln()
            ..writeln(remedy);
        }
        b
          ..writeln()
          ..writeln(
            'Tell me how you want them handled and I will fix the rest - the '
            'build follows by itself once nothing is left.',
          );
      }
    }
    return AssistantReply(
      _join(opening, b.toString().trimRight()),
      quickReplies: _nextStepsFor(repair.plan, blocked: repair.remaining),
      intent: 'fix',
      repairedPlan: repair.plan,
      repairedFixes: repair.fixes,
    );
  }

  static final RegExp _missingAccountRule = RegExp(
    r'^(\S+)\s+(\S+)\s+rule has an account missing username or password',
  );

  /// What is left to say for the findings the repair pass could NOT clear.
  ///
  /// The generic examples "fix the plan" otherwise offers are the wrong
  /// advice for a missing credential: no amount of topology talk adds a
  /// password, and a user who kept saying "fix the plan" was told to move
  /// subnets instead of being told the one thing the app needs from them. The
  /// same is true of the other classes the app cannot decide on its own - how
  /// many ports a switch needs, which VLANs to create - so each one is named
  /// with the sentence that settles it.
  static String _remedyFor(List<ValidationIssue> issues, {NetworkIntent? plan}) {
    final logins = <String>[];
    final extra = <String>[];
    void addLogin(String label) {
      if (!logins.contains(label)) logins.add(label);
    }

    void addRemedy(String remedy) {
      if (!extra.contains(remedy)) extra.add(remedy);
    }

    for (final issue in issues) {
      final m = _missingAccountRule.firstMatch(issue.message);
      if (m != null) {
        addLogin('${m.group(1)!} (${m.group(2)!.toUpperCase()})');
        continue;
      }
      // The same gap said the other way round: the server exists and holds no
      // account at all, which is the shape a profile-based brief lands in.
      if (issue.message.startsWith('The AAA server holds no account')) {
        final server = plan?.security.aaaServer?.trim() ?? '';
        addLogin(server.isEmpty ? 'the AAA server' : '$server (AAA)');
        continue;
      }
      if (issue.message.contains('has no addressing entry')) {
        addRemedy(
          'a device with no address needs a LAN to take one from: say which '
          'subnet it is on, or ask me to add the switch it belongs to',
        );
        continue;
      }
      if (issue.message.contains('has only') &&
          issue.message.contains('ports')) {
        addRemedy(
          'a switch with more cables than ports needs another switch: say '
          '"add another switch" (or name a bigger model - a 3560 has 24 '
          'FastEthernet plus 4 GigabitEthernet) and I plan it in',
        );
        continue;
      }
      if (issue.message.contains('Inter-VLAN routing') ||
          issue.message.contains('VLAN')) {
        addRemedy(
          'VLAN work needs the VLAN list: say "VLANs 10, 20 and 30" and I '
          'create them and put the ports in them',
        );
      }
    }
    final b = StringBuffer();
    if (logins.isNotEmpty) {
      b.writeln(
          'This one is a login, so it is the one thing only you can supply: '
          'say "AAA username admin password 123" - name the server instead of '
          'AAA when there is more than one, here ${logins.join(', ')} - and I '
          'write that account into the server\'s Services tab. That sentence '
          'is the whole fix; it is the only way this finding can clear.',
        );
    }
    for (final remedy in extra) {
      if (b.isNotEmpty) b.writeln();
      b.writeln('$remedy.');
    }
    return b.toString().trimRight();
  }

  /// A short question asked while a plan exists is a follow-up about that plan,
  /// not a fresh start - say so, the way a person keeping notes would.
  static String _continuity(
    NetworkIntent? plan,
    String t,
    List<ChatMessage> history,
  ) {
    if (plan == null || plan.nodes.isEmpty || history.isEmpty) return '';
    final words = t.split(_whitespace).where((w) => w.isNotEmpty).length;
    if (words > 6) return '';
    return 'For the lab you have planned (${_labLine(plan)}):\n\n';
  }

  /// The plan in one clause, using plurals a person would use.
  static String _labLine(NetworkIntent plan) {
    String many(int n, String one, String plural) =>
        '$n ${n == 1 ? one : plural}';
    int count(String type) => plan.nodes.where((n) => n.type == type).length;
    final bits = <String>[
      if (count('router') > 0) many(count('router'), 'router', 'routers'),
      if (count('switch') > 0) many(count('switch'), 'switch', 'switches'),
      if (count('pc') > 0) many(count('pc'), 'PC', 'PCs'),
      if (count('server') > 0) many(count('server'), 'server', 'servers'),
      if (plan.vlans.isNotEmpty) 'VLANs ${plan.vlans.join(', ')}',
      if (plan.routing != 'static') plan.routing.toUpperCase(),
      if (plan.security.requested) 'security controls',
    ];
    return bits.isEmpty ? '${plan.nodes.length} device(s)' : bits.join(', ');
  }

  static String _join(String a, String b) => a.trim().isEmpty ? b : '$a\n\n$b';

  /// Deterministic variety: the same conversation always gets the same words.
  static String _pick(List<String> options, int seed) =>
      options[seed.abs() % options.length];

  // --- intent detection ---------------------------------------------------

  /// Greetings only. "thanks" and "ok" are acknowledgements ([_isAck]), and
  /// answering them as a hello is what made the chat feel deaf.
  static const Set<String> _greetings = {
    'hi', 'hello', 'hey', 'yo', 'sup', 'salam', 'salaam', 'hola',
    'hiya', 'heyo', 'howdy', 'greetings', 'good day',
    'good morning', 'good evening', 'good afternoon',
    // Arabic greetings, so an Arabic opener gets the greeting branch (and
    // the Arabic greeting text) rather than the vague fallback.
    'مرحبا', 'مرحباً', 'مرحبتين', 'اهلا', 'أهلا', 'أهلاً', 'هلا', 'السلام عليكم',
    'صباح الخير', 'مساء الخير',
  };

  static bool _isGreeting(String t) =>
      _greetings.contains(t) ||
      t.startsWith('hi ') ||
      t.startsWith('hello ') ||
      t.startsWith('hey ') ||
      t.startsWith('hiya ') ||
      t.startsWith('heyo ') ||
      t.startsWith('howdy ') ||
      t.startsWith('greetings ') ||
      t.startsWith('good day ') ||
      t.startsWith('مرحبا ') ||
      t.startsWith('اهلا ') ||
      t.startsWith('أهلا ');

  /// Farewells. "later" is a goodbye here, not a "no", so this is read
  /// before the yes/no branch; "cheers" stays an acknowledgement on purpose.
  static final RegExp _byePattern = RegExp(
    r'^(bye|bye bye|goodbye|good\s+bye|see\s+ya|see\s+you|see\s+you\s+later|'
    r'later|catch\s+you\s+later|good\s+night|goodnight|farewell|'
    r'مع السلامة|الى اللقاء|إلى اللقاء|وداعا|باي باي|باي|تصبح على خير)'
    r'[.!؟]*$',
  );

  static bool _isBye(String t) => _byePattern.hasMatch(t);

  // --- identity ------------------------------------------------------------

  /// "who made you", "who created you" - answered without inventing a
  /// maker: there is no company or person to name, and making one up is
  /// exactly the kind of confidence the offline path exists to avoid.
  static final RegExp _identityMadeBy = RegExp(
    r'who\s+(made|created|built|designed|programmed)\s+you\b',
  );

  /// "are you an AI / a bot / a human?" - the honesty question.
  static final RegExp _identityAi = RegExp(
    r'are\s+you\s+((really|actually|just)\s+)?(an?\s+)?'
    r'(ai|a\.i|bot|human|person|robot|real)\b|'
    r'do\s+you\s+(use|run)\s+(a\s+)?(model|llm|gpt|gemini)\b',
  );

  /// "who are you", "what are you", "what's your name".
  static final RegExp _identityWho = RegExp(
    r'\b(who|what)\s+(are|r)\s+you\b|'
    r"what(?:'?s|\s+is)\s+your\s+name\b|"
    r'who\s+am\s+i\s+talking\s+to\b',
  );

  /// "what can you do", "what do you do", "what are you for", "what's new".
  static final RegExp _identitySkills = RegExp(
    r'\bwhat\s+(can|could)\s+you\s+do\b|'
    r'\bwhat\s+(else\s+)?do\s+you\s+do\b|'
    r'\bwhat\s+are\s+you\s+for\b|'
    r'\bwhat\s+do\s+you\s+support\b|'
    r'\bwhat\s+are\s+your\s+(features|skills|abilities|capabilities)\b|'
    r"what(?:'?s|\s+is)\s+new\b",
  );

  /// "how are you", "how's it going" - small talk, but about the assistant.
  static final RegExp _identityWellbeing = RegExp(
    r'\bhow\s+(are|r)\s+you\b|'
    r"how.?s\s+it\s+going\b|"
    r'are\s+you\s+(ok|okay|alright|good)\s*[?.!]*$',
  );

  /// "are you offline", "do you need internet/wifi", "can you work
  /// offline". Matched BEFORE the networking-vocabulary guard, because
  /// these name the very words the guard looks for: "do you need wifi?" is
  /// a question about the assistant even though it says wifi.
  static final RegExp _identityOfflineNet = RegExp(
    r'are\s+you\s+((really|fully|always|actually)\s+)?'
    r'(offline|local|on(ne)?\s+this\s+device|on\s+device)\b|'
    r'\b(can|do|does)\s+(you|it|this)\s+work\s+'
    r'(offline|without\s+(the\s+)?internet|without\s+(the\s+)?wifi)\b|'
    r'\bdo\s+you\s+need\s+(the\s+)?(internet|wifi|wi-fi|a\s+model|an\s+api)\b',
  );

  /// The key variants of the offline ask. These wait until AFTER the guard:
  /// "do you need a key" can just as easily be an SSH or WPA question, and
  /// the networking vocabulary in the sentence ('ssh', 'wpa') is what tells
  /// those apart from a question about the assistant's own API key.
  static final RegExp _identityOfflineKey = RegExp(
    r'\bdo\s+you\s+need\s+(an?\s+)?(api\s+)?key\b|'
    r'\bdo\s+you\s+work\s+without\s+(a\s+key|an\s+api\s+key)\b|'
    r'\bwork(s|ing)?\s+(without|with\s+no)\s+(an?\s+)?(api\s+)?key\b|'
    r'\bkey\s+(needed|required)\b',
  );

  /// Arabic identity questions, matched by substring: word-boundary regexes
  /// do not behave on Arabic script (every Arabic letter is a non-word char
  /// to \b), so contains() is the honest matcher here. The dialect forms
  /// people actually type sit next to the MSA ones. Kept to question
  /// shapes, so an Arabic build request that happens to mention them is
  /// never swallowed.
  static const List<String> _arabicIdentityWho = [
    'من أنت', 'من انت', 'مين انت', 'ما اسمك', 'شو اسمك', 'من صنعك', 'من أنشأك',
    'هل أنت ذكاء', 'هل انت ذكاء', 'هل أنت إنسان', 'هل انت انسان',
    'هل أنت روبوت', 'هل أنت بوت', 'هل انت بوت',
  ];
  static const List<String> _arabicIdentitySkills = [
    'ماذا تفعل', 'ماذا تستطيع', 'ما الذي تستطيع', 'وش تقدر', 'ايش تقدر',
    'إيش تقدر', 'وش تقدم', 'ماذا تقدم', 'ما الجديد', 'وش الجديد',
    'ايش الجديد', 'إيش الجديد',
  ];
  static const List<String> _arabicIdentityWellbeing = [
    'كيف حالك', 'كيف الحال', 'كيفك', 'شخبارك', 'اخبارك', 'أخبارك',
  ];
  static const List<String> _arabicIdentityOffline = [
    'هل تعمل دون اتصال', 'هل تعمل بدون انترنت', 'هل تعمل بدون إنترنت',
    'هل تحتاج انترنت', 'هل تحتاج إنترنت', 'هل تحتاج مفتاح',
    'هل يعمل بدون مفتاح', 'هل يعمل بدون انترنت',
  ];

  /// Which identity question [t] asks, or null when it is not one. The
  /// guard comes first (except for the offline asks about the internet or
  /// wifi, which name the very words the guard looks for): a message that
  /// carries networking vocabulary keeps its route.
  static String? _identityKind(String t) {
    if (_identityOfflineNet.hasMatch(t)) return 'offline';
    if (_deviceWords.hasMatch(t) || _networkWords.hasMatch(t)) return null;
    if (_identityOfflineKey.hasMatch(t)) return 'offline';
    if (_identityMadeBy.hasMatch(t)) return 'made';
    if (_identityAi.hasMatch(t)) return 'ai';
    if (_identitySkills.hasMatch(t)) return 'skills';
    if (_identityWho.hasMatch(t)) return 'who';
    if (_identityWellbeing.hasMatch(t)) return 'wellbeing';
    return _arabicIdentityKind(t);
  }

  static String? _arabicIdentityKind(String t) {
    if (_arabicIdentityOffline.any(t.contains)) return 'offline';
    if (_arabicIdentityWellbeing.any(t.contains)) return 'wellbeing';
    if (_arabicIdentitySkills.any(t.contains)) return 'skills';
    if (_arabicIdentityWho.any(t.contains)) return 'who';
    return null;
  }

  /// Example prompts for the identity replies - all three are things the
  /// offline path answers for real, so a tap is never a dead end.
  static const List<String> _identityReplies = [
    '2 routers, 1 switch and 4 PCs with OSPF',
    'What is better, OSPF or static routing?',
    'How do I configure PAT overload?',
  ];

  /// What the assistant says about itself, by kind. Honest by design: it is
  /// a rule-based local assistant, and every answer says where the line is.
  static String _identityAnswer(String kind, int seed) {
    switch (kind) {
      case 'made':
        return 'I am built into NetBuilder AI as its offline brain - rules '
            'that run on this device, not a model in a cloud. There is no '
            'company to call and no account to sign into; every answer is '
            'computed right here.';
      case 'ai':
        return 'I am a local, rule-based assistant - no model, no cloud, no '
            'API key. That is why the same question always gets the same '
            'answer, and why nothing you type ever leaves this device. It '
            'is also why I say so plainly when something is not in my '
            'offline material.';
      case 'skills':
        return 'I can do a few concrete things, all on this device:\n\n'
            '- Plan a lab from plain words: "2 routers, 1 switch and 4 PCs '
            'with OSPF".\n'
            '- Build the real .pkt file - no Packet Tracer needed.\n'
            '- Answer config questions: "how do I configure SSH?", "what is '
            'a wildcard mask?".\n'
            '- Do subnet math: "what is the broadcast address of '
            '192.168.10.5/26?".\n'
            '- Give design advice: "which router should I get for a home?".\n'
            '- Repair a plan: say "fix the plan" and I clear what can be '
            'cleared.\n\n'
            'Ask one of these, or just describe your network.';
      case 'wellbeing':
        return _pick(const [
          'Running fast - everything is local, so there is no server to '
              'wait on. What are we building?',
          'All good - no key to check and no server to wait on. What are we '
              'building?',
        ], seed);
      case 'offline':
        return 'Yes - fully offline. Planning, building the .pkt, the '
            'answers and the repairs all run on this device: no API key, no '
            'cloud and no internet needed, and nothing you type leaves it.';
      default: // 'who'
        return 'I am the NetBuilder assistant - a fully offline networking '
            'copilot. I plan labs from plain language, compile real Packet '
            'Tracer .pkt files on this device, answer Cisco config and '
            'subnet questions, and repair plans. No API key, and nothing '
            'you type leaves this device.';
    }
  }

  /// The Arabic companions of [_identityAnswer]: the same honesty, in the
  /// user's language, with the technical examples kept in English (commands
  /// ARE English).
  static String _identityAnswerAr(String kind, int seed) {
    switch (kind) {
      case 'made':
        return 'أني مدمج في NetBuilder AI كعقل يعمل دون اتصال - قواعد تعمل '
            'على جهازك، لا نموذج في السحابة. لا شركة تُستدعى ولا حساب '
            'يُسجَّل فيه؛ كل جواب يُحسب هنا.';
      case 'ai':
        return 'أنا مساعد محلي يعمل بالقواعد - لا نموذج ولا سحابة ولا مفتاح '
            'API. لهذا يكون الجواب نفسه دائماً للسؤال نفسه، ولا يخرج شيء '
            'مما تكتبه من جهازك. وأقول بصراحة عندما يكون السؤال خارج ما '
            'أغطيه دون اتصال.';
      case 'skills':
        return 'أستطيع أشياء محددة، وكلها على جهازك:\n\n'
            '- تخطيط معمل من وصف بسيط: "2 routers, 1 switch and 4 PCs with '
            'OSPF".\n'
            '- بناء ملف .pkt حقيقي دون Packet Tracer.\n'
            '- الإجابة عن أسئلة الإعداد: "how do I configure SSH?".\n'
            '- حسابات الشبكات الفرعية: "what is a wildcard mask?".\n'
            '- نصائح التصميم: "which router should I get for a home?".\n'
            '- إصلاح الخطة: قل "fix the plan".\n\n'
            'جرّب أحدها، أو صِف شبكتك بكلماتك.';
      case 'wellbeing':
        return _pick(const [
          'بخير - كل شيء محلي على جهازك، فلا انتظار لأي خادم. ماذا نبني؟',
          'تمام - لا مفتاح ولا خادم ننتظره. ماذا نبني؟',
        ], seed);
      case 'offline':
        return 'نعم - دون اتصال تماماً. التخطيط وبناء ملف .pkt والإجابات '
            'والإصلاحات كلها تعمل على جهازك: لا مفتاح API ولا سحابة ولا '
            'إنترنت، ولا شيء مما تكتبه يخرج منه.';
      default: // 'who'
        return 'أنا مساعد NetBuilder - يعمل بالكامل دون اتصال. أخطط المعامل '
            'من وصف بسيط، وأبني ملفات Packet Tracer حقيقية على جهازك، وأجيب '
            'عن أسئلة إعداد Cisco وحسابات الشبكات، وأصلح الخطط. بلا مفتاح '
            'API، ولا شيء مما تكتبه يخرج من جهازك.';
    }
  }

  /// "what did I ask you to build?", "remind me", "as I said" - a
  /// question about the conversation itself, answered from memory.
  ///
  /// The spellings are the ones people actually type: "what was i asking for",
  /// "what were we doing", "do you still remember", "what did you just build".
  static final RegExp _recallPattern = RegExp(
    r'\b(what (did|was|were) (i|my|we|you)|remind me|what did i (ask|say|tell|'
    r'mean|want)|my (first|original|earlier) (ask|request|message|idea)|'
    r'as i (asked|said)|what was the (original|first)|do you remember|'
    r'do you still remember|what (were|are) we (doing|building|working on)|'
    r'what did you (just )?(build|make|create)|what have you (built|made)|'
    r'what file|which file|where (is|was) the file)\b',
  );

  static bool _isRecall(String t) => _recallPattern.hasMatch(t);

  /// Answer a recall question with the user's own words, oldest first.
  static String _recallAnswer(
    List<String> asks,
    String normalized,
    NetworkIntent? plan,
  ) {
    final current = normalized.trim().toLowerCase();
    final prior = <String>[
      for (final ask in asks)
        if (current.isEmpty ||
            !current.contains(
              ask.toLowerCase().substring(0, ask.length < 24 ? ask.length : 24),
            ))
          ask,
    ];
    if (prior.isEmpty) {
      return 'This is the start of our conversation - you have not asked me '
          'for anything yet. Tell me what you want to build and I will plan '
          'it, or ask me a networking question.';
    }
    final b = StringBuffer()
      ..writeln('Here is what you have asked me, oldest first:')
      ..writeln();
    for (var i = 0; i < prior.length; i++) {
      b.writeln('${i + 1}. ${prior[i]}');
    }
    b.writeln();
    b.writeln('Your ORIGINAL request was: "${prior.first}".');
    if (plan != null && plan.nodes.isNotEmpty) {
      b.writeln(
        'I still hold the plan for it: '
        '${plan.nodes.map((n) => n.name).join(', ')}.',
      );
    }
    return b.toString().trimRight();
  }

  static final RegExp _changeVerb = RegExp(
    r'\b(add|adding|change|changing|set|update|remove|delete|rename|convert|replace|switch it|make it|turn it|modify)\b',
  );
  static final RegExp _deviceCount = RegExp(
    r'\d+\s*(routers?|switches|switch|pcs?|servers?|laptops?|printers?|firewalls?)',
  );

  /// A WH-word, anywhere in the sentence. [_howtoShaped] only looks at the
  /// START of the message, which is why "2 routers and 4 switches, what is
  /// the best colour for the cable" read as a build request and the question
  /// in the middle of it went unanswered.
  static final RegExp _whWord = RegExp(
    r'\b(what|why|how|which|where|who|whose|when)\b',
    caseSensitive: false,
  );

  /// Devices and protocols that make a short message a topic ("and vlans?")
  /// rather than an opener ("hmm") - and that mark an identity opener
  /// wearing a network question ("what can you do about the OSPF
  /// adjacency") as a real question. One list, so both readers agree.
  static final RegExp _deviceWords = RegExp(
    r'\b(router|routers|switch|switches|pc|pcs|server|servers|laptop|'
    r'laptops|printer|printers|firewall|ap|wifi|wireless|vlan|vlans|ospf|'
    r'eigrp|bgp|subnet|subnets|network|networks|lab|labs|office|site|'
    r'sites|dhcp|dns|aaa|vpn|acl|tacacs|nat|rip|isis|bgp|phone|phones|'
    r'camera|cameras|ip phone|wireless router|access point)\b',
  );

  /// Networking words the device list above misses, but that still say
  /// "this is a network question" to the identity guard: PAT, the internet
  /// itself, interfaces, neighbours.
  static final RegExp _networkWords = RegExp(
    r'\b(internet|pat|interfaces?|gateways?|wans?|lans?|spanning|'
    r'adjacency|adjacencies|neighbou?rs?|ethernet|packet tracer|ios|cli)\b',
  );

  static final RegExp _useChange = RegExp(
    r'\buse\s+(?:ospf|eigrp|bgp|rip|static|a\s+\d|'
    r'\d{1,3}(?:\.\d{1,3}){3})',
  );

  static bool _isChange(String t) {
    if (t.isEmpty) return false;
    // "add 2 routers" is a build request, not a change to an existing plan.
    if (_deviceCount.hasMatch(t)) return false;
    // "how do I change the hostname?" asks HOW it is done; it is not an
    // instruction to change the standing plan.
    if (_howtoShaped(t)) {
      return false;
    }
    // "use ospf" / "use a 4331" / "use 192.168.30.0/24" are instructions to
    // change the standing plan - they are literally the phrasings the
    // app's own suggestion chips and examples use. Without this clause
    // they fell to the build answer, whose change-delta line happened to
    // carry the news; with the plan-aware composer on that path, the
    // change must be claimed here first.
    final useChange = _useChange.hasMatch(t);
    return _changeVerb.hasMatch(t) || useChange;
  }

  /// A question about HOW something is done rather than an instruction:
  /// the shape check the concept reader and the plan-aware rescue both
  /// apply before a device count can mean "build brief".
  static bool _howtoShaped(String t) =>
      t.startsWith('how ') ||
      t.startsWith('what ') ||
      t.startsWith('where ') ||
      t.startsWith('which ') ||
      t.startsWith('why ') ||
      t.endsWith('?');

  static final RegExp _fixVerb = RegExp(
    r'^(fix|repair|solve|resolve|correct|mend|clear)\b',
  );
  static final RegExp _fixTarget = RegExp(
    r'\b(plan|it|them|these|those|this|everything|all|errors?|findings?|'
    r'problems?|issues?|duplicates?|conflicts?|warnings?|blockers?|network|'
    r'lab)\b',
  );

  static final RegExp _questionLead = RegExp(
    r'^(how|what|why|when|where|which|who|is|are|does|do)\b',
  );

  static final RegExp _politeLead = RegExp(
    r'^(?:can|could|would|will|please|kindly)\s+(?:you\s+)?',
  );

  static final RegExp _trailingPunct = RegExp(r'[?.!,;\u061f\u060c\s]+$');

  static final RegExp _bareFixVerb = RegExp(
    r'^(fix|repair|solve|resolve|correct|mend|clear)$',
  );

  /// True when the message is an INSTRUCTION to repair the standing plan
  /// rather than a question about repair.
  ///
  /// This is the reader behind the reported "I told it in the chat to fix the
  /// plan and it didn't": "fix" was not a change verb, so the message fell
  /// through to the build branch and the answer described the same broken plan
  /// again. Public because the chat runs the same test before it consults a
  /// model, so the behaviour does not depend on whether a key is set.
  static bool looksLikeRepairRequest(String text) {
    var t = text.trim().toLowerCase();
    if (t.isEmpty) return false;
    // "how do I fix an OSPF neighbour?" asks how, and "why is it broken?"
    // asks why: neither is an instruction to change this plan.
    if (_questionLead.hasMatch(t)) {
      return false;
    }
    // "Can you fix the plan?" is a request, however politely it is phrased.
    t = t.replaceFirst(_politeLead, '');
    t = t.replaceAll(_trailingPunct, '');
    if (!_fixVerb.hasMatch(t)) return false;
    // "fix 2 routers" is a build request, not a repair of what stands.
    if (_deviceCount.hasMatch(t)) return false;
    // A bare verb, or a verb with the thing it repairs named.
    return _fixTarget.hasMatch(t) || _bareFixVerb.hasMatch(t);
  }

  static bool _isFix(String t) => looksLikeRepairRequest(t);

  static final RegExp _thenBuild = RegExp(
    r'\b(then|and|then\s+please|after\s+that|afterwards|after)\b[^.]{0,20}?'
    r'\b(build|compile|generate|produce|write|create|make)\b',
  );

  static final RegExp _buildIt = RegExp(
    r'\b(build|compile|generate|produce|write)\s+(it|that|them|the\s+'
    r"(?:file|\.?pkt|lab|network))\b",
  );

  /// True when a repair request also asks for the BUILD in the same breath:
  /// "fix every finding you got then build", "repair the plan and compile it".
  ///
  /// Without this the sentence was answered literally - the app repaired the
  /// plan and then waited for a second click on a card the user had already
  /// asked for, which is what "fix every finding then build is still a no-op"
  /// was describing. The repair runs first either way; this only decides
  /// whether the build follows it without being asked twice.
  static bool asksToBuildAfterRepair(String text) {
    if (!looksLikeRepairRequest(text)) return false;
    final t = text.toLowerCase();
    return _thenBuild.hasMatch(t) || _buildIt.hasMatch(t);
  }

  /// The findings that would withhold a build for [plan], with the same
  /// validator call and target the build card uses. Public so the chat can ask
  /// "did the repair clear it?" and act on the answer (build now, or say what
  /// is still in the way) without duplicating the gate.
  static List<ValidationIssue> blockingFindings(
    NetworkIntent plan, {
    String target = 'packet-tracer',
  }) => _blocking(plan, target);

  static final RegExp _modelNumber = RegExp(
    r'\b(4331|4321|2911|2901|1941|2960|2950|3560|829)\b',
  );

  static final RegExp _cidrPrefix = RegExp(
    r'\b(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\b',
  );

  static final Map<String, RegExp> _routingWords = {
    for (final p in const ['ospf', 'eigrp', 'bgp', 'static'])
      p: RegExp('\\b$p\\b'),
  };

  static String _describeChange(String t) {
    final bits = <String>[];
    final model = _modelNumber.firstMatch(t);
    if (model != null && t.contains('router')) {
      bits.add('use the ${model.group(1)} model for the routers');
    } else if (model != null && t.contains('switch')) {
      bits.add('use the ${model.group(1)} model for the switches');
    } else if (model != null) {
      bits.add('use model ${model.group(1)}');
    }
    final cidr = _cidrPrefix.firstMatch(t);
    if (cidr != null) bits.add('move the LANs onto ${cidr.group(1)}');
    if (t.contains('vlan')) {
      bits.add('create the VLAN on the switches and put its ports in it');
    }
    for (final p in const ['ospf', 'eigrp', 'bgp', 'static']) {
      if (_routingWords[p]!.hasMatch(t)) {
        bits.add('use $p for routing');
        break;
      }
    }
    if (bits.isEmpty) bits.add('apply the change you described to the current plan');
    return 'Got it - I would ${bits.join(', and ')}.';
  }

  /// A plan-composed "Your lab:" section for [topic], or null. Null when
  /// there is no plan, the topic is not one the composer can ground, or the
  /// plan cannot support the topic - in all three the generic answer stands
  /// alone, which is exactly the fail-closed contract.
  static String? _groundedSection(
    String? topic,
    NetworkIntent? plan,
    String target,
  ) {
    if (topic == null || plan == null) return null;
    if (!PlanConfigComposer.topics.contains(topic)) return null;
    return PlanConfigComposer.compose(
      plan: plan,
      topic: topic,
      target: target,
    );
  }

  /// Explicit exits from an active troubleshooting flow. Anchored so a
  /// real answer to the flow's question ("no, never mind that port") is
  /// not mistaken for an exit - only a leading "stop/never mind/..." quits.
  static final RegExp _flowExit = RegExp(
    r"^\s*(stop|never\s?mind|forget\s+it|quit\s+this|cancel\s+(this|the)\s+"
    r'(diagnos|flow|troubleshoot)|exit\s+this)\b',
  );

  static final RegExp _ipv4Address = RegExp(r'\d{1,3}(?:\.\d{1,3}){3}');

  static final RegExp _stpWord = RegExp(r'\bstp\b');

  static final RegExp _loopWord = RegExp(r'\bloops?\b');

  static final RegExp _ipv6Prefix = RegExp(r'[0-9a-f:]{3,}\s*/\s*\d{1,3}');

  static final Map<String, RegExp> _conceptWords = {
    for (final w in const [
      'ospf', 'eigrp', 'bgp', 'static', 'vs', 'difference', 'which', 'trunk',
      'dhcp', 'dns', 'vlan', 'vlans', 'router', 'routers', 'nat', 'acl', 'nd',
      'dr',
    ])
      w: RegExp('\\b$w\\b'),
  };

  static String? _concept(String rawText) {
    // Full names and fault phrasings are canonicalized to the short forms
    // this chain matches on ("border gateway protocol" reaches the bgp
    // explainer, "network address translation" the NAT one). The knowledge
    // table applies the same canonicalization to its own input, so a
    // paraphrase that has no concept hook still reaches its corpus entry.
    final t = CasualEnglish.canonical(rawText);
    // A device COUNT means a build request, not a concept question. A model
    // number inside a how-to ("...a 2960 switch") is not a count, so a
    // question still gets its answer. (The battery test caught the old
    // behaviour: "how do I configure a trunk port on a 2960 switch" fell
    // through to the vague reply because of the 2960.)
    final howtoShaped = t.startsWith('how ') ||
        t.startsWith('what ') ||
        t.startsWith('where ') ||
        t.startsWith('which ') ||
        t.startsWith('why ') ||
        t.endsWith('?');
    if (!howtoShaped && _deviceCount.hasMatch(t)) return null;
    // A recommendation request ("what is your recommendations?", "what
    // would you do?") is answered by [AdvisorService] BEFORE this reader is
    // consulted, so the old 'enterprise' shortcut that turned every
    // "recommend" into one canned blueprint is gone: the advisor's answer
    // is grounded in the request and the plan instead of always naming a
    // two-site company network.
    bool has(String w) => _conceptWords[w]!.hasMatch(t);
    if ((has('ospf') || has('eigrp') || has('bgp')) &&
        (has('static') ||
            has('vs') ||
            has('difference') ||
            has('which') ||
            t.contains('better') ||
            t.contains(' or '))) {
      return 'routing';
    }
    if (has('trunk') || t.contains('access port')) return 'trunk';
    if (has('dhcp') &&
        // DHCPv6 is its own topic (RA flags, M/O bits), so a dhcpv6
        // question - even a mixed "dhcpv6 vs dhcp" one, or phrased as
        // "dhcp for ipv6" - falls through to the knowledge table instead
        // of getting the DHCPv4 answer.
        !t.contains('dhcpv6') &&
        !t.contains('ipv6') &&
        !t.contains('snoop') &&
        !t.contains('relay') &&
        !t.contains('helper')) {
      return 'dhcp';
    }
    if (has('dns') && !t.contains('reverse') && !t.contains('ptr')) {
      return 'dns';
    }
    // "and vlans?" gets the VLAN answer, but a message that is really
    // about DHCP relay or snooping on a VLAN belongs to that topic's
    // answer (the knowledge table below owns them).
    if ((has('vlan') || has('vlans')) &&
        !t.contains('relay') &&
        !t.contains('helper') &&
        !t.contains('snoop')) {
      return 'vlan';
    }
    if ((t.contains('connect') || t.contains('link') || t.contains('between')) &&
        (has('router') || has('routers'))) {
      return 'two_routers';
    }
    if (has('nat') || t.contains('internet')) return 'internet';
    if (has('acl') || t.contains('access list')) return 'acl';
    // A subnet question carrying a real address/prefix is computed by the
    // offline knowledge table (network, broadcast, usable hosts); the
    // generic explainer only answers the "what is a subnet mask" style
    // question.
    if ((t.contains('subnet') || t.contains('mask')) &&
        !t.contains('/') &&
        !_ipv4Address.hasMatch(t)) {
      return 'subnet';
    }
    // The wider expert set: routing, switching, services, transport,
    // security, wireless and IPv6.
    // Whole-word 'stp' only: 'rstp' is rapid spanning tree - a different
    // mode with its own commands - and the old substring test swallowed it
    // into the classic STP answer.
    if (_stpWord.hasMatch(t) ||
        t.contains('spanning') ||
        _loopWord.hasMatch(t)) {
      return 'stp';
    }
    if (t.contains('etherchannel') || t.contains('port-channel') ||
        t.contains('lag')) {
      return 'etherchannel';
    }
    if (t.contains('mtu') || t.contains('mss') || t.contains('fragment')) {
      return 'mtu';
    }
    if (t.contains('retransmit') || t.contains('tcp') ||
        t.contains('window') || t.contains('handshake')) {
      return 'tcp';
    }
    if (t.contains('nat') || t.contains('pat')) return 'internet';
    if (t.contains('qos') || t.contains('priority queue') ||
        t.contains('dscp')) {
      return 'qos';
    }
    if (t.contains('roam') || t.contains('channel') ||
        t.contains('802.11') || t.contains('rssi')) {
      return 'wireless';
    }
    // A concrete IPv6 address/prefix is computed by the knowledge table;
    // the generic explainer answers the concept question. An ask that is
    // really about DHCP on IPv6 ("set up dhcp for ipv6") falls through to
    // the DHCPv6 corpus entry - the address plan, not the concept.
    if ((t.contains('ipv6') || t.contains('slaac') || has('nd')) &&
        !has('dhcp') &&
        !_ipv6Prefix.hasMatch(t)) {
      return 'ipv6';
    }
    if (t.contains('ospf area') || has('dr') || t.contains('lsa')) {
      return 'ospf_internals';
    }
    if (t.contains('eigrp')) return 'eigrp';
    if (t.contains('bgp')) return 'bgp';
    if (t.contains('default route') || t.contains('gateway of last')) {
      return 'default_route';
    }
    return null;
  }

  static String _conceptAnswer(String key) {
    switch (key) {
      case 'routing':
        return 'Static routes are fine for one router or a single path - simple '
            'and predictable. OSPF is better once you have two or more routers: '
            'it learns the paths, converges around a failed link, and you stop '
            'hand-writing every network. For a graded lab with 2+ routers I '
            'would pick OSPF (single area 0).';
      case 'trunk':
        return 'An access port belongs to a single VLAN and faces an end device '
            '(PC, printer). A trunk carries several VLANs at once and faces '
            'another switch or a router. So: access ports for the PCs, a trunk '
            'between the switches.';
      case 'dhcp':
        return 'If DHCP is not handing out addresses, check three things: the '
            'pool network/mask matches the interface, the pool default gateway '
            'is the router LAN IP, and for a remote LAN you need "ip '
            'helper-address <server>" on that router interface.';
      case 'dns':
        return 'Point every client at the DNS server IP (set it on the DHCP pool '
            'or statically on the PC), then add A records on the server for the '
            'names you want to resolve.';
      case 'vlan':
        return 'Create the VLAN on the switch, put the user ports in it as access '
            'ports, and trunk the uplink so the VLAN reaches the rest of the '
            'network. Hosts in different VLANs need a router or an L3 switch to '
            'talk to each other.';
      case 'two_routers':
        return 'Connect two routers either with a serial link (s0/0/0 on both '
            'ends, clock rate on the DCE side) or with an Ethernet /30 transit '
            'link. Give each LAN its own subnet, then either add static routes '
            'or run OSPF.';
      case 'internet':
        return 'For internet access put a Cloud-PT or a firewall at the edge '
            'and give the router a default route toward it. The NAT itself '
            'is PAT overload on the WAN interface:\n'
            '1. Name the two sides: `ip nat inside` on the LAN interface, '
            '`ip nat outside` on the WAN one.\n'
            '2. Define the inside addresses that may go out: `access-list '
            '100 permit ip 192.168.1.0 0.0.0.255 any`.\n'
            '3. Tie them together: `ip nat inside source list 100 interface '
            'g0/1 overload`.\n'
            'One inside server that must stay reachable from the outside '
            'gets a static mapping instead: `ip nat inside source static '
            'tcp 192.168.1.10 80 interface g0/1 80`.\n'
            'Verify with `show ip nat translations` and `show ip nat '
            'statistics` - translations piling up on the outside interface '
            'means it is working.';
      case 'acl':
        return 'Standard ACLs filter by source only - place them near the '
            'destination. Extended ACLs filter by source, destination, protocol '
            'and port - place them near the source. Remember the implicit "deny '
            'any" at the end.';
      case 'subnet':
        return 'Give each LAN its own subnet with the router holding the first '
            'usable address (.1) as the gateway. A /24 gives 254 hosts; a /30 is '
            'the usual choice for a point-to-point link between two routers.';
      case 'stp':
        return 'Spanning tree breaks Layer-2 loops by blocking redundant '
            'ports. One root bridge is elected (lowest bridge ID), then every '
            'other switch keeps one root port and each segment one designated '
            'port. Check with `show spanning-tree` and find the blocked port by '
            'walking the topology towards the root.';
      case 'etherchannel':
        return 'EtherChannel bundles up to 8 same-speed links into one logical '
            'link. Match the settings on both ends (mode, allowed VLANs, speed) '
            'or the bundle stays down: `channel-group 1 mode active` with LACP '
            'on both sides, then verify with `show etherchannel summary` (flag '
            'SU = in use).';
      case 'mtu':
        return 'TCP MSS is the payload size that fits the path MTU minus the '
            'IP+TCP headers. A tunnel adds overhead, so set the inside MSS with '
            '`ip tcp adjust-mss 1360` on the tunnel interface when MTU 1500 '
            'breaks. Symptoms of an MSS/MTU problem: small pings work, large '
            'pings and logins hang.';
      case 'tcp':
        return 'A TCP session is SYN, SYN-ACK, ACK. Retransmissions mean an '
            'unacknowledged segment was resent (loss, congestion or a broken '
            'return path); duplicate ACKs hint at one dropped segment, while a '
            'zero-window says the receiver is full. Check RTT and window '
            'scaling before blaming the application.';
      case 'qos':
        return 'Classify first, then queue: mark at the edge (DSCP EF for '
            'voice, AF41 for video), trust DSCP on the uplinks, and give the '
            'latency-sensitive classes a priority queue while everything else '
            'shares a weighted queue. Policing drops, shaping delays - choose '
            'per direction.';
      case 'wireless':
        return 'Roaming is the client\'s decision: it moves when the new AP is '
            'better by about 10-15 dBm. Make sure the same SSID and security '
            'exist on every AP, keep 2.4 GHz on channels 1/6/11 and use 5 GHz '
            'for throughput. Sticky clients usually mean the coverage overlap is '
            'too small.';
      case 'ipv6':
        return 'IPv6 has no broadcast and no NAT. A router advertises prefixes '
            'with RA, and hosts can self-configure with SLAAC; if you want a '
            'managed DHCPv6 address, set the RA flags M/O. Verify with `show '
            'ipv6 interface brief` and `show ipv6 route`.';
      case 'ospf_internals':
        return 'In a broadcast segment OSPF elects a DR and BDR to cut the '
            'number of adjacencies; everyone else stays in 2-WAY with them. Set '
            'the router-id and interface priorities deliberately. `show ip ospf '
            'neighbor` shows the state, `show ip ospf database` the LSAs.';
      case 'eigrp':
        return 'EIGRP picks routes by composite metric (bandwidth and delay '
            'by default) and keeps a feasible successor for instant '
            'failover. Configuring it (classic mode - the AS number must '
            'match on every router):\n'
            '1. `router eigrp 100`.\n'
            '2. `network 10.1.0.0 0.0.0.255` - the wildcard mask, not the '
            'subnet mask.\n'
            '3. `passive-interface g0/0` on interfaces with no EIGRP '
            'neighbour (or `passive-interface default`, then `no '
            'passive-interface s0/0/0` for the WAN link).\n'
            'Verify with `show ip eigrp neighbors` and `show ip route '
            'eigrp` - the neighbour must be up before any route appears.';
      case 'bgp':
        return 'BGP chooses by weight, then local preference, then AS-path '
            'length, then origin, then MED. Basic eBGP between two '
            'routers:\n'
            '1. `router bgp 65001` - your AS number.\n'
            '2. `neighbor 10.0.0.2 remote-as 65002` - the peer address and '
            'its AS; the two routers must be able to ping each other '
            'first.\n'
            '3. `network 192.168.1.0 mask 255.255.255.0` - only prefixes '
            'already in the routing table get advertised.\n'
            'Verify with `show ip bgp summary`: State/PfxRcd should show a '
            'prefix count, not Idle or Active. Packet Tracer supports this '
            'basic eBGP session.';
      case 'default_route':
        return 'A default route (0.0.0.0/0) is the gateway of last resort. '
            'Static: `ip route 0.0.0.0 0.0.0.0 <next-hop>`. In OSPF inject it '
            'with `default-information originate`; in EIGRP or BGP redistribute '
            'it. Nothing more specific may exist, or that wins instead.';
      default:
        return 'Tell me the platform and the symptom and I will pin it '
            'down. Useful shape for any networking problem: (1) what changed '
            'last, (2) what is the exact symptom and scope (one host, one '
            'VLAN, one direction?), (3) work up the stack - link, addressing, '
            'routing, then service - and check each with one command before '
            'moving on.';
    }
  }

  // --- answers ------------------------------------------------------------

  static String _buildAnswer(
    NetworkIntent plan,
    List<String> suggestions,
    String originalAsk, {
    String opening = '',
    NetworkIntent? previousPlan,
    String target = 'packet-tracer',
  }) {
    final routers = plan.nodes.where((n) => n.type == 'router').length;
    final switches = plan.nodes.where((n) => n.type == 'switch').length;
    final pcs = plan.nodes.where((n) => n.type == 'pc').length;
    final servers = plan.nodes.where((n) => n.type == 'server').length;
    final others = plan.nodes.length - routers - switches - pcs - servers;

    final sb = StringBuffer();
    if (opening.trim().isNotEmpty) {
      sb
        ..writeln(opening)
        ..writeln();
    }
    // What changed since the last turn, so a follow-up reads as a continuation
    // of one conversation rather than a fresh description of a lab.
    final delta = NetworkIntent.planChangeSummary(previousPlan, plan);
    if (delta.isNotEmpty) {
      sb.writeln('That updates the lab you had: $delta.');
      sb.writeln();
    }
    final parts = <String>[
      if (routers > 0) '$routers router(s)',
      if (switches > 0) '$switches switch(es)',
      if (pcs > 0) '$pcs PC(s)',
      if (servers > 0) '$servers server(s)',
      if (others > 0) '$others other device(s)',
    ];
    // The total is stated as well as the breakdown, so the number the user
    // reads here is the same number the build card and the .pkt report. A
    // summary that only listed the parts left nothing to compare against a
    // card that said "2 device(s), 0 link(s)".
    sb.writeln(
      'Here is the lab I understand: ${parts.join(', ')} '
      '(${plan.nodes.length} device(s) in total).',
    );
    if (originalAsk.isNotEmpty) {
      sb.writeln(
        'This follows what you asked earlier: "$originalAsk".',
      );
    }
    sb.writeln('Devices: ${plan.nodes.map((n) => n.name).join(', ')}.');
    // The revision travels with every count, so a number in this paragraph is
    // always traceable to one plan version and can be compared with what the
    // build card and the .pkt say.
    sb.writeln(
      'Links: ${plan.links.length}, routing: ${plan.routing} '
      '(rev ${plan.revision}).',
    );
    if (plan.addressing.isNotEmpty) {
      sb.writeln(
        'Addressing: ${plan.addressing.take(6).map((a) => '${a.node} ${a.iface}=${a.ipCidr}').join(', ')}'
        '${plan.addressing.length > 6 ? ' ...' : ''}',
      );
    }
    sb.writeln();
    sb.writeln('Advice:');
    if (plan.routing == 'static' && routers > 1) {
      sb.writeln('- With more than one router, OSPF is usually easier than '
          'hand-written static routes - say "use ospf" to switch.');
    }
    if (switches > 1) {
      // Advice has to describe the plan that will actually be built: telling
      // the user to trunk a link that is not in the plan sends them looking
      // for a cable that does not exist.
      final switchNames = plan.nodes
          .where((n) => n.type == 'switch')
          .map((n) => n.name.toLowerCase())
          .toSet();
      final trunk = plan.links.any(
        (l) =>
            switchNames.contains(l.a.toLowerCase()) &&
            switchNames.contains(l.b.toLowerCase()),
      );
      if (trunk) {
        sb.writeln('- Make the switch-to-switch cable a trunk and leave the '
            'device ports as access ports.');
      } else {
        sb.writeln('- The switches are not cabled to each other in this plan, '
            'so there is no trunk yet - say "add a trunk between the '
            'switches" and I will add the link as well as the config.');
      }
    }
    final noRole =
        plan.nodes.where((n) => n.type == 'server' && n.services.isEmpty).length;
    if (noRole > 0) {
      sb.writeln('- Give each server a role (DHCP, DNS, HTTP, AAA, ...) so its '
          'service tab is actually configured.');
    }
    if (!plan.security.requested) {
      sb.writeln('- If this is a secure/graded lab, add port security on the '
          'user ports plus an ACL or VPN - I can plan those too.');
    }
    // The findings that hold the build card back, stated as the same list the
    // card shows, so the advice and the disabled button tell one story.
    final blocking = _blocking(plan, target);
    if (blocking.isNotEmpty) {
      sb.writeln();
      sb.writeln('Fix these first:');
      for (final issue in blocking.take(6)) {
        sb.writeln('- [${issue.severity}] ${issue.message}');
      }
      if (blocking.length > 6) {
        sb.writeln('- ... and ${blocking.length - 6} more.');
      }
    } else if (suggestions.isNotEmpty) {
      sb.writeln();
      sb.writeln('Worth knowing:');
      for (final s in suggestions.take(6)) {
        sb.writeln('- $s');
      }
    }
    sb.writeln();
    if (blocking.isNotEmpty) {
      // Saying "press Build" here while the card below refuses to build is
      // the dead end the user reported. Name the blocker and the way out.
      sb.writeln('Next steps:');
      sb.writeln('1. The Build card on this reply is withheld: this plan still '
          'has ${blocking.length} finding(s) that would be baked into the '
          '.pkt. Fix them above (tell me what to change, or edit the plan in '
          'the network inspector) and the build unlocks.');
      sb.writeln('2. Tell me anything that is wrong or missing and I will keep '
          'the plan moving - I hold on to it between messages.');
      sb.writeln();
      sb.writeln('Nothing is built or typed into Packet Tracer until you '
          'approve it.');
      return sb.toString();
    }
    sb.writeln('Next steps:');
    sb.writeln('1. Press "Build the .pkt" on this reply - it compiles the plan '
        'into a real file offline, with no Packet Tracer and no API key.');
    sb.writeln('2. Open the file in Packet Tracer and check it against your '
        'brief.');
    sb.writeln('3. Tell me anything that is wrong or missing and I will keep '
        'the plan moving - I hold on to it between messages.');
    sb.writeln();
    sb.writeln('Nothing is typed into Packet Tracer until you approve it.');
    return sb.toString();
  }

  static String _vagueAnswer(String originalAsk) =>
      'I am here - I just need a bit more to go on.\n\n'
      '${originalAsk.isEmpty ? '' : 'Earlier in this conversation you asked: '
          '"$originalAsk". Do you want me to build on that, or is this '
          'something new?\n\n'}'
      'Tell me what you want in plain words, for example:\n'
      '- "2 routers, 2 switches, 1 server and 4 PCs with OSPF"\n'
      '- "a small office with guest wifi and port security"\n'
      '- "connect two routers over a serial WAN and add a DNS server"\n\n'
      'Three things make a plan complete in one go:\n'
      '1. How many routers, switches, PCs and servers do you want?\n'
      '2. Static routes or OSPF?\n'
      '3. Any security - port security, an ACL or a VPN?\n\n'
      'Or just ask a question, like "what is better, OSPF or static routing?".';

  /// The short Arabic opener answer: honest, in the user's language, without
  /// pretending to have parsed a plan request it cannot read.
  static const _vagueAnswerAr =
      'أنا هنا - أخبرني ماذا تريد أن تبني أو اسألني سؤالاً عن الشبكات '
      '(بالعربية أو الإنجليزية)، وسأجاوِبك دون اتصال.\n\n'
      'استخدم أسماء الأجهزة بالإنجليزية، مثلاً: "2 routers, 1 switch and '
      '4 PCs with OSPF".';

  /// The Arabic framing line prepended to English technical answers: device
  /// commands really are English, and saying so beats a wall of unexplained
  /// English.
  static const _arabicLead =
      'أوامر الأجهزة إنجليزية، لذا سأشرح بالإنجليزية - واطلب توضيح أي خطوة '
      'وسأعيدها بالعربية.';

  /// The honest answer when the offline material does not cover a question.
  static const _missingCoverage =
      'That one is not in my offline material. Without a model I cover '
      'planning, device configuration steps, verification commands, subnet '
      'math and the common faults - try naming the device or protocol (for '
      'example "how do OSPF areas work"), or add a model key in Settings '
      'for open-ended questions.';

  static const _arabicMissing =
      'هذا السؤال خارج ما لديّ دون اتصال. أُغطّي التخطيط وخطوات إعداد '
      'الأجهزة وأوامر التحقق وحسابات الشبكات والأعطال الشائعة - جرّب تسمية '
      'الجهاز أو البروتوكول (مثلاً "how do OSPF areas work")، أو أضف مفتاح '
      'مزود في الإعدادات للأسئلة المفتوحة.';

  /// The reply to a real question the offline material does not cover.
  ///
  /// A flat "not covered" line wastes the one thing this assistant HAS: a
  /// wide, honest corpus one topic away. Before falling back to it, the
  /// user's words are matched against [_topicCatalog] - the areas the
  /// offline path genuinely answers - and the nearest topics are named,
  /// with their sample questions offered as quick replies. Every sample is
  /// a question the offline path really answers, so a tap is never a dead
  /// end. With nothing near, the honest line stays: a wrong suggestion is
  /// worse than none.
  static AssistantReply _missingReply(
    String t, {
    required bool arabic,
    required String opening,
    NetworkIntent? plan,
  }) {
    final near = _nearTopics(t);
    if (near.isEmpty) {
      return AssistantReply(
        _join(opening, arabic ? _arabicMissing : _missingCoverage),
        quickReplies: _nextStepsFor(plan),
        intent: 'missing',
      );
    }
    final b = StringBuffer()
      ..writeln(
        'That one is not in my offline material - but I can answer these '
        'nearby questions:',
      )
      ..writeln();
    for (final entry in near) {
      b.writeln('- ${entry.topic}');
    }
    return AssistantReply(
      _join(
        opening,
        '${arabic ? '$_arabicLead\n\n' : ''}${b.toString().trimRight()}',
      ),
      quickReplies: [for (final entry in near) entry.sample],
      intent: 'missing',
    );
  }

  /// The topics the offline material actually covers, for the near-miss
  /// reply above. The sample question is what gets tapped, so each one is
  /// traced to a real answer: the computed subnet/wildcard/summarization
  /// entries, the concept explainers, the config battery, the advisor and
  /// the planner itself (the .pkt build).
  static const List<({String topic, String sample})> _topicCatalog = [
    (topic: 'Subnet math and VLSM', sample: 'how many hosts does a /28 subnet support'),
    (topic: 'Wildcard masks', sample: 'what is the wildcard mask for /27'),
    (topic: 'Route summarization', sample: 'how does route summarization work'),
    (topic: 'VLANs', sample: 'how do VLANs work'),
    (topic: 'Inter-VLAN routing', sample: 'what is router-on-a-stick'),
    (
      topic: 'Trunk vs access ports',
      sample: 'what is the difference between a trunk and an access port',
    ),
    (topic: 'Spanning tree (STP)', sample: 'how does spanning tree work'),
    (topic: 'EtherChannel', sample: 'how does EtherChannel work'),
    (topic: 'DHCP', sample: 'how does DHCP work'),
    (topic: 'DNS', sample: 'how do I point the PCs at a DNS server'),
    (topic: 'NAT and internet access', sample: 'how do I configure PAT overload'),
    (topic: 'ACLs', sample: 'what is an ACL'),
    (topic: 'OSPF', sample: 'how do I verify OSPF neighbors'),
    (topic: 'EIGRP', sample: 'how does EIGRP work'),
    (topic: 'BGP', sample: 'how does BGP work'),
    (topic: 'Static and default routes', sample: 'static route syntax'),
    (topic: 'HSRP', sample: 'how do I configure HSRP'),
    (topic: 'SSH access', sample: 'how do I configure SSH on a switch'),
    (topic: 'Port security', sample: 'how do I enable port security on a switch'),
    (topic: 'VPN and IPsec', sample: 'how do I configure a site-to-site VPN'),
    (topic: 'Wireless and wifi', sample: 'how to secure wifi with WPA2'),
    (topic: 'IPv6', sample: 'how does IPv6 addressing work'),
    (
      topic: 'Ping and traceroute faults',
      sample: 'request timed out when pinging across routers',
    ),
    (topic: 'Packet Tracer basics', sample: 'how do I add a device in Packet Tracer'),
    (topic: 'Design and sizing advice', sample: 'which router should I get for a home?'),
    (topic: 'Building the .pkt', sample: '2 routers, 1 switch and 4 PCs with OSPF'),
  ];

  /// Words that carry no topic meaning on either side of the comparison:
  /// question scaffolding and verbs so generic that matching on them would
  /// suggest topics at random.
  static const Set<String> _topicStopwords = {
    'what', 'how', 'why', 'when', 'where', 'which', 'who', 'is', 'are',
    'was', 'were', 'am', 'be', 'been', 'do', 'does', 'did', 'i', 'you',
    'your', 'me', 'my', 'we', 'us', 'it', 'its', 'this', 'that', 'these',
    'those', 'there', 'here', 'a', 'an', 'the', 'to', 'for', 'of', 'in',
    'on', 'at', 'by', 'with', 'without', 'from', 'into', 'and', 'or', 'if',
    'can', 'could', 'should', 'would', 'will', 'shall', 'may', 'might',
    'must', 'need', 'needs', 'want', 'use', 'used', 'using', 'work',
    'works', 'working', 'set', 'setup', 'get', 'gets', 'got', 'make',
    'making', 'configure', 'configuring', 'config', 'tell', 'show', 'see',
    'look', 'about', 'up', 'out', 'off', 'many', 'much', 'right', 'best',
    'good', 'instead', 'also', 'just',
  };

  static final RegExp _tokenSeparators = RegExp(r'[^a-z0-9+#]+');

  /// The content words of [t]. Lowercased first: the token pattern only
  /// accepts a-z, so an unlowercased 'VLSM' or 'OSPF' would be shredded
  /// into separator characters and the topic would lose its best word.
  static Set<String> _contentTokens(String t) {
    final out = <String>{};
    for (final w in t.toLowerCase().split(_tokenSeparators)) {
      if (w.length < 2 || _topicStopwords.contains(w)) continue;
      out.add(w);
    }
    return out;
  }

  /// A tolerant stem: plurals and -ing, so 'switches' meets 'switch' and
  /// 'pinging' meets 'ping'. Deliberately crude - it only has to decide
  /// whether two words are about the same thing, not parse English.
  static String _topicStem(String w) {
    for (final suffix in const ['ing', 'ies', 'es', 's']) {
      if (w.length > suffix.length + 2 && w.endsWith(suffix)) {
        return w.substring(0, w.length - suffix.length);
      }
    }
    return w;
  }

  static bool _tokensMeet(String a, String b) {
    final sa = _topicStem(a);
    final sb = _topicStem(b);
    if (sa == sb) return true;
    // Short technical words ('nat', 'stp', 'acl') must match exactly - a
    // prefix rule on three letters would tie unrelated acronyms together.
    // Longer words may share a stem ('switch' / 'switchport').
    if (sa.length >= 4 &&
        sb.length >= 4 &&
        (sa.startsWith(sb) || sb.startsWith(sa))) {
      return true;
    }
    return false;
  }

  /// How near a catalog topic sits to what the user asked: the share of
  /// the SMALLER side's content words the two have in common. At least one
  /// shared word is required, so an unrelated question (an email campaign,
  /// say) matches nothing at all, and the 0.3 floor keeps a single stray
  /// word from dragging a topic in.
  static double _topicScore(Set<String> asked, String topicText) {
    final topicTokens = _contentTokens(topicText);
    if (topicTokens.isEmpty || asked.isEmpty) return 0;
    var shared = 0;
    for (final w in topicTokens) {
      if (asked.any((a) => _tokensMeet(a, w))) shared++;
    }
    if (shared == 0) return 0;
    final smaller =
        asked.length < topicTokens.length ? asked.length : topicTokens.length;
    return shared / smaller;
  }

  /// Up to 3 catalog topics nearest to [t], best first; ties keep catalog
  /// order so the offer is stable for the same question.
  static List<({String topic, String sample})> _nearTopics(String t) {
    final asked = _contentTokens(t);
    if (asked.isEmpty) return const [];
    final scored = <(int, double)>[];
    for (var i = 0; i < _topicCatalog.length; i++) {
      final entry = _topicCatalog[i];
      final score = _topicScore(asked, '${entry.topic} ${entry.sample}');
      if (score >= 0.3) scored.add((i, score));
    }
    scored.sort((a, b) {
      final byScore = b.$2.compareTo(a.$2);
      return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
    });
    return [for (final (i, _) in scored.take(3)) _topicCatalog[i]];
  }

  static final RegExp _openWhLead = RegExp(
    r'^(what|why|how|which|where|who)\b',
  );

  static final RegExp _openArabicLead = RegExp(
    r'^(ما|ماذا|كيف|لماذا|هل|أين|من)',
  );

  /// A real question the offline material did not match. Deliberately
  /// narrow: a two-word opener belongs to the vague path, and a stated
  /// device count belongs to the planner.
  ///
  /// The old version also refused when the text named routers, switches,
  /// PCs, servers, a lab or a plan - so a technology question that happened
  /// to name a device met a plan dump or the vague reply instead of an
  /// honest gap. The advisor ([AdvisorService]) is consulted BEFORE this,
  /// so an advice question has already had its expert answer; a question
  /// about the plan itself still gets the plan answer below.
  static bool _openQuestion(String t, int wordCount, {bool hasPlan = false}) {
    if (wordCount < 3) return false;
    final shaped = t.endsWith('?') ||
        t.endsWith('؟') ||
        _openWhLead.hasMatch(t) ||
        _openArabicLead.hasMatch(t);
    if (!shaped) return false;
    if (_deviceCount.hasMatch(t)) return false;
    // With a plan on the table, an unmatched question is answered by the
    // build reply that describes that plan - the standing behaviour, kept
    // deliberately: it is the only answer that uses the lab's real names.
    if (hasPlan) return false;
    return true;
  }

  static const List<String> _vagueQuestions = [
    'How many routers, switches, PCs and servers do you want?',
    'Should routing be static or OSPF?',
    'Do you need security (port security, an ACL, or a VPN)?',
  ];

}
