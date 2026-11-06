import '../../models/network_intent.dart';
import '../casual_english.dart';
import '../config_paste_reader.dart';
import '../design_library.dart';
import '../file_edit_intent.dart';
import '../lab_report.dart';
import '../layout_intent.dart';
import '../networking_help_reader.dart';
import '../scope_gate.dart';
import 'requested_action_reader.dart';

enum RequestDispatch { helpOnly, specialized, generalPlan }

/// Early handlers that must run before general request parsing.
///
/// Keep this order aligned with the handler order in chat. Several handlers
/// inspect saved conversation state or perform asynchronous reads, so this
/// list selects an ordered candidate path without invoking those effects.
enum EarlyRequestHandler {
  command,
  rememberedRouting,
  configPaste,
  undo,
  packetAnalysisFollowup,
  scanDiff,
  lab,
  labReport,
  packetTracerModelChoice,
  planRepair,
}

class EarlyRequestSelection {
  final bool answerSmallTalkImmediately;
  final List<EarlyRequestHandler> handlers;

  const EarlyRequestSelection({
    required this.answerSmallTalkImmediately,
    required this.handlers,
  });
}

/// Side-effect-free routing evidence shared by online and offline chat.
/// Existing domain readers still decide what a layout, file edit, or named
/// design means; this selector only decides which path owns the turn.
class RequestRouteSelection {
  final RequestDispatch dispatch;
  final bool hasNamedDesign;
  final LayoutRequest? layoutRequest;
  final FileEditIntent fileIntent;

  const RequestRouteSelection({
    required this.dispatch,
    required this.hasNamedDesign,
    required this.layoutRequest,
    required this.fileIntent,
  });

  bool get helpOnly => dispatch == RequestDispatch.helpOnly;
  bool get coordinatorOwnsPlan => dispatch == RequestDispatch.generalPlan;
}

class RequestRouteSelector {
  const RequestRouteSelector._();

  static const List<EarlyRequestHandler> _handlersWithoutTextMatches = [
    EarlyRequestHandler.command,
    EarlyRequestHandler.rememberedRouting,
    EarlyRequestHandler.undo,
    EarlyRequestHandler.packetAnalysisFollowup,
    EarlyRequestHandler.scanDiff,
    EarlyRequestHandler.lab,
    EarlyRequestHandler.packetTracerModelChoice,
    EarlyRequestHandler.planRepair,
  ];

  /// Chooses the ordered pre-parser handler candidates without running them.
  ///
  /// The command and conversation-state handlers still decide whether they
  /// own the turn. Config-paste and lab-report readers are pure, so their
  /// candidates are included only when their existing match rules succeed.
  /// Edits skip this entire early path, matching the current chat behavior.
  static EarlyRequestSelection selectEarly({
    required String text,
    required bool isEditing,
    required bool hasPendingAttachments,
  }) {
    if (isEditing) {
      return const EarlyRequestSelection(
        answerSmallTalkImmediately: false,
        handlers: [],
      );
    }

    if (!hasPendingAttachments && ScopeGate.isSmallTalk(text)) {
      return const EarlyRequestSelection(
        answerSmallTalkImmediately: true,
        handlers: [],
      );
    }

    final handlers = <EarlyRequestHandler>[];
    for (final handler in _handlersWithoutTextMatches) {
      if (handler == EarlyRequestHandler.undo &&
          ConfigPasteReader.matches(text)) {
        // Pasted configs are reviewed before undo requests, just as in chat.
        handlers.add(EarlyRequestHandler.configPaste);
      }
      if (handler == EarlyRequestHandler.packetTracerModelChoice &&
          LabReportRequest.matches(text)) {
        // Reports are read after the guided lab handler and before model
        // compatibility choices.
        handlers.add(EarlyRequestHandler.labReport);
      }
      handlers.add(handler);
    }

    return EarlyRequestSelection(
      answerSmallTalkImmediately: false,
      handlers: handlers,
    );
  }

  /// Keep output requests and direct edits out of the advice-only path.
  /// This same gate is used before online parsing and during offline fallback.
  static bool isHelpOnly(String text) {
    final hasRequestedAction = RequestedActionReader.read(
      text: text,
      turnId: 'route',
    ).isNotEmpty;
    if (hasRequestedAction) return false;
    return NetworkingHelpReader.matches(text) ||
        const {
          'howto',
          'question',
          'advice',
          'social',
          'empty',
        }.contains(NetworkIntent.classifyBrief(CasualEnglish.normalize(text)));
  }

  static RequestRouteSelection select({
    required String text,
    String? designText,
    required bool hasArtifact,
    int artifactCandidates = 0,
    String currentLayoutStyle = 'tree',
  }) {
    final helpOnly = isHelpOnly(text);
    if (helpOnly) {
      return const RequestRouteSelection(
        dispatch: RequestDispatch.helpOnly,
        hasNamedDesign: false,
        layoutRequest: null,
        fileIntent: FileEditIntent.none,
      );
    }

    final namedDesign = DesignApplier.namedIn(designText ?? text) != null;
    final layoutRequest = LayoutRequest.read(
      text,
      currentStyle: currentLayoutStyle,
    );
    final fileIntent = FileEditIntentReader.read(
      text,
      hasArtifact: hasArtifact,
      candidates: artifactCandidates,
    );
    final specialized =
        namedDesign ||
        layoutRequest != null ||
        fileIntent != FileEditIntent.none;
    return RequestRouteSelection(
      dispatch: specialized
          ? RequestDispatch.specialized
          : RequestDispatch.generalPlan,
      hasNamedDesign: namedDesign,
      layoutRequest: layoutRequest,
      fileIntent: fileIntent,
    );
  }
}
