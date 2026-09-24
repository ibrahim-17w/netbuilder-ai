import 'dart:async';

import 'tool_protocol.dart';

/// One thing that happened during an investigation.
class ToolLoopEvent {
  /// status | result | final | limit | error
  final String kind;
  final String text;
  final ToolCall? call;
  final Object? data;
  const ToolLoopEvent(this.kind, this.text, {this.call, this.data});
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
  Stream<ToolLoopEvent> run(List<Map<String, dynamic>> messages) async* {
    final working = [for (final m in messages) Map<String, dynamic>.from(m)];
    var rounds = 0;

    while (true) {
      if (rounds >= maxIterations) {
        yield ToolLoopEvent(
          'limit',
          'Stopped after $maxIterations investigation rounds to avoid a loop. '
          'Here is what the tools established so far.',
        );
        return;
      }
      rounds++;

      final Object? reply;
      try {
        reply = await send(working);
      } catch (e) {
        yield ToolLoopEvent('error', e.toString().replaceFirst('Exception: ', ''));
        return;
      }

      final calls = ToolProtocol.parseCalls(reply);

      // No more tools wanted: the text is the answer.
      if (calls.isEmpty) {
        yield ToolLoopEvent('final', extractText(reply), data: reply);
        return;
      }

      // Echo the assistant's request, then answer each call in order.
      working.add(ToolProtocol.assistantTurn(calls));
      for (final call in calls) {
        yield ToolLoopEvent('status', ToolProtocol.statusLine(call), call: call);
        Object? result;
        try {
          result = await execute(call);
        } catch (e) {
          // A failed tool is information, not a dead end: tell the model.
          result = {
            'error': e.toString().replaceFirst('Exception: ', ''),
            'tool': call.name,
          };
        }
        yield ToolLoopEvent(
          'result',
          '${call.name} -> ${_short(result)}',
          call: call,
          data: result,
        );
        working.add(ToolProtocol.resultMessage(call, result));
      }
    }
  }

  static String _short(Object? value) {
    final text = value?.toString() ?? '';
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 160 ? one : '${one.substring(0, 160)}...';
  }
}
