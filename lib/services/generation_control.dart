import 'dart:async';

/// The stop signal for ONE turn.
///
/// [cancel] completes it, which is what the transports watch: an
/// `http.AbortableRequest` drops the connection, and a stream that is already
/// arriving stops instead of being read to the end. Cancelling a turn must not
/// leave a socket open until the provider's own timeout fires - that is how a
/// cancelled answer kept writing into the next one.
class TurnAbort {
  final Completer<void> _completer = Completer<void>();

  /// Whether the user has already pressed stop for this turn.
  bool get aborted => _completer.isCompleted;

  /// The future the transports pass as their abort trigger. It completes
  /// without an error, which is what `http.AbortableRequest` requires.
  Future<void> get future => _completer.future;

  void abort() {
    if (_completer.isCompleted) return;
    _completer.complete();
  }
}

/// Thrown when a turn was stopped by the user.
///
/// It is deliberately NOT an [AiErrors]-style provider failure: the provider
/// did nothing wrong, and reporting it as one sends the caller down the
/// "provider is down, fall back to the offline assistant" path for an answer
/// the user cancelled on purpose. Callers check the abort signal (spec §11).
class AbortedException implements Exception {
  final String message;

  const AbortedException([
    this.message = 'That answer was cancelled.',
  ]);

  @override
  String toString() => 'AbortedException: $message';
}

/// Watches an abort trigger so a cancelled turn is never mistaken for a failed
/// one.
///
/// [isAbortError] lets the caller name the transport's own abort error
/// (`http.RequestAbortedException`), which some clients throw instead of
/// completing the trigger first.
class AbortSignal {
  AbortSignal(
    Future<void>? trigger, {
    bool Function(Object error)? isAbortError,
    bool Function()? isAbortedNow,
  })  : _matchesError = isAbortError,
        _probe = isAbortedNow {
    if (trigger == null) return;
    // A trigger that fails must not take the answer down with it.
    trigger.then<void>((_) => _aborted = true, onError: (Object _) {});
  }

  final bool Function(Object error)? _matchesError;

  /// A synchronous read of the same fact, for the case the future cannot
  /// answer: a turn that was stopped BEFORE this request was built.
  ///
  /// A completed future is only observable in a later microtask, so a signal
  /// created after the cancel saw `false` and let the request go out anyway -
  /// the user pressed stop and the model answered regardless.
  final bool Function()? _probe;
  bool _aborted = false;

  /// Whether the trigger has completed.
  bool get isAborted => _aborted || (_probe?.call() ?? false);

  /// Whether [error] is this turn's cancellation rather than a real failure.
  bool isAbortError(Object error) =>
      isAborted || (_matchesError?.call(error) ?? false);

  /// Stop here if the user already pressed stop.
  void throwIfAborted([String message = 'That answer was cancelled.']) {
    if (isAborted) throw AbortedException(message);
  }
}

/// The deadlines every chat request gets.
///
/// A chat turn used to have exactly one timeout on one code path, so a
/// provider that accepted the connection and then said nothing left the user
/// looking at an empty bubble until the OS gave up. These are the numbers that
/// make "still waiting" say itself.
class StreamDeadlines {
  const StreamDeadlines._();

  /// How long a provider may take to send response headers (or the first byte
  /// of a non-streaming body).
  static const Duration firstByte = Duration(seconds: 60);

  /// The longest silence inside a stream. A model that is thinking between
  /// tokens can be slow, but it does not go quiet for three quarters of a
  /// minute and then continue.
  static const Duration idle = Duration(seconds: 45);

  /// The ceiling for one whole streamed answer.
  static const Duration total = Duration(minutes: 5);

  /// One tool call into the engine's tool layer. It is a local call against a
  /// loaded capture, so a slow one means the sidecar is stuck, not thinking.
  static const Duration toolCall = Duration(seconds: 30);

  /// A whole non-streaming request.
  static const Duration oneShot = Duration(seconds: 90);

  /// A sidecar that is asked whether it has tools at all.
  static const Duration discovery = Duration(seconds: 10);

  /// Guard [source] with the idle and total budgets.
  ///
  /// `Stream.timeout` raises a [TimeoutException] when the source goes quiet
  /// for [idleGap]; the total budget is checked on every chunk so a chatty but
  /// endless stream is still stopped. Both surface as timeouts, which the
  /// callers already translate into something the user can act on.
  static Stream<T> guarded<T>(
    Stream<T> source, {
    DateTime? startedAt,
    Duration? idleGap,
    Duration? budget,
  }) {
    final start = startedAt ?? DateTime.now();
    final gap = idleGap ?? idle;
    final limit = budget ?? total;
    final watched = source.transform(
      StreamTransformer<T, T>.fromHandlers(
        handleData: (data, sink) {
          if (DateTime.now().difference(start) >= limit) {
            sink.addError(
              TimeoutException(
                'The answer took longer than ${_human(limit)} to arrive.',
                limit,
              ),
            );
            sink.close();
            return;
          }
          sink.add(data);
        },
      ),
    );
    return gap <= Duration.zero ? watched : watched.timeout(gap);
  }

  static String _human(Duration d) =>
      d.inMinutes >= 1 ? '${d.inMinutes} minute(s)' : '${d.inSeconds}s';
}

/// Cancels a streaming answer without unwinding anything else.
///
/// A token is handed out when a turn starts; the streaming loop checks it as
/// each piece arrives and stops consuming when the token is no longer current.
/// Text already written stays on screen - cancelling stops the answer, it does
/// not erase what the user has already read.
class GenerationControl {
  int _id = 0;
  bool _cancelled = false;
  TurnAbort? _turn;

  int get id => _id;
  bool get cancelled => _cancelled;

  /// The stop signal for the turn in flight, or null before the first [begin].
  TurnAbort? get turnAbort => _turn;

  /// The abort trigger to hand the transports, or null when nothing is running.
  Future<void>? get abortTrigger => _turn?.future;

  /// Start a turn and return its token.
  int begin() {
    _cancelled = false;
    // Whatever was still in flight belongs to the turn being replaced: its
    // request is aborted now, not in sixty seconds' time.
    _turn?.abort();
    _turn = TurnAbort();
    return ++_id;
  }

  /// Stop the current turn. Any token handed out before this is now stale.
  void cancel() {
    _cancelled = true;
    _turn?.abort();
    _id++;
  }

  /// Whether [token] still belongs to the turn the user is waiting on.
  bool isCurrent(int token) => !_cancelled && token == _id;
}
