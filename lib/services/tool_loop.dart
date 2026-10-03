import 'dart:async';

import 'generation_control.dart';
import 'tool_protocol.dart';

/// The kinds of thing the loop reports.
///
/// Spelled out as constants because the callers switch on them: `error` used
/// to be the one kind nothing typed, so "the provider refused" and "the user
/// pressed stop" were the same string - and the second one is not a failure.
class ToolLoopEventKind {
  const ToolLoopEventKind._();

  static const String status = 'status';
  static const String result = 'result';

  /// The model's answer. Named `finalAnswer` because `final` is a keyword.
  static const String finalAnswer = 'final';

  /// The investigation cap was reached (spec §3).
  static const String limit = 'limit';

  /// The provider leg failed. Not a user cancellation - that raises
  /// [AbortedException] instead of emitting anything.
  static const String error = 'error';

  static const List<String> all = [status, result, finalAnswer, limit, error];
}

/// One thing that happened during an investigation.
class ToolLoopEvent {
  /// One of the [ToolLoopEventKind] values.
  final String kind;
  final String text;
  final ToolCall? call;
  final Object? data;
  const ToolLoopEvent(this.kind, this.text, {this.call, this.data});

  /// A provider failure, as opposed to anything else the loop can report.
  bool get isError => kind == ToolLoopEventKind.error;
}

typedef ToolSender = Future<Object?> Function(List<Map<String, dynamic>>);
typedef ToolExecutor = Future<Object?> Function(ToolCall call);
typedef TextExtractor = String Function(Object?);

/// The bounded investigate-then-answer loop (spec §3).
///
/// The model is given the tool catalogue; while it asks for tools the loop
/// runs them against the network engine and feeds the results back; when it
/// stops asking, its text is the answer.
///
/// Every side effect is injected ([send], [execute], [extractText]), so the
/// loop itself is pure orchestration and can be tested without a network or a
/// model. That also keeps the chat's existing path available as a fallback.
class ToolLoop {
  final ToolSender send;
  final ToolExecutor execute;
  final TextExtractor extractText;

  /// "a reasonable maximum number of iterations to prevent infinite loops"
  /// (spec §3). Hitting it is reported, never hidden.
  final int maxIterations;

  const ToolLoop({
    required this.send,
    required this.execute,
    required this.extractText,
    this.maxIterations = 6,
  });

  /// [messages] must already contain the system prompt, the conversation and
  /// the new user turn, in the shape the provider expects.
  ///
  /// Rich `content` (a screenshot's `image_url` part) is carried through to
  /// every round trip untouched: the loop is where a vision turn used to lose
  /// its image, because the working copy flattened content to a string.
  Stream<ToolLoopEvent> run(List<Map<String, dynamic>> messages) async* {
    final working = [for (final m in messages) _copy(m)];
    var rounds = 0;

    while (true) {
      if (rounds >= maxIterations) {
        yield ToolLoopEvent(
          ToolLoopEventKind.limit,
          'Stopped after $maxIterations investigation rounds to avoid a loop. '
          'Here is what the tools established so far.',
        );
        return;
      }
      rounds++;

      final Object? reply;
      try {
        reply = await send(working);
      } on AbortedException {
        // The user pressed stop. That is not a provider failure and must not
        // be reported as one.
        rethrow;
      } catch (e) {
        yield ToolLoopEvent(
          ToolLoopEventKind.error,
          e.toString().replaceFirst('Exception: ', ''),
        );
        return;
      }

      final calls = ToolProtocol.parseCalls(reply);

      // No more tools wanted: the text is the answer.
      if (calls.isEmpty) {
        yield ToolLoopEvent(
          ToolLoopEventKind.finalAnswer,
          extractText(reply),
          data: reply,
        );
        return;
      }

      // Echo the assistant's request, then answer each call in order.
      working.add(ToolProtocol.assistantTurn(calls));
      for (final call in calls) {
        yield ToolLoopEvent(
          ToolLoopEventKind.status,
          ToolProtocol.statusLine(call),
          call: call,
        );
        Object? result;
        try {
          result = await execute(call);
        } on AbortedException {
          rethrow;
        } catch (e) {
          // A failed tool is information, not a dead end: tell the model.
          result = {
            'error': e.toString().replaceFirst('Exception: ', ''),
            'tool': call.name,
          };
        }
        yield ToolLoopEvent(
          ToolLoopEventKind.result,
          '${call.name} -> ${_short(result)}',
          call: call,
          data: result,
        );
        working.add(ToolProtocol.resultMessage(call, result));
      }
    }
  }

  /// A private copy of one message.
  ///
  /// The `content` array is copied part by part rather than shared, so a turn
  /// that carries an image reaches every provider round trip as the parts the
  /// caller built - and the caller's list cannot be changed underneath the
  /// loop while it is running.
  static Map<String, dynamic> _copy(Map<String, dynamic> message) {
    final copy = Map<String, dynamic>.from(message);
    final content = copy['content'];
    if (content is List) {
      copy['content'] = [
        for (final part in content)
          part is Map ? Map<String, dynamic>.from(part) : part,
      ];
    }
    return copy;
  }

  static String _short(Object? value) {
    final text = value?.toString() ?? '';
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 160 ? one : '${one.substring(0, 160)}...';
  }
}
