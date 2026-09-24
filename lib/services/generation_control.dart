/// Cancels a streaming answer without unwinding anything else.
///
/// A token is handed out when a turn starts; the streaming loop checks it as
/// each piece arrives and stops consuming when the token is no longer current.
/// Text already written stays on screen - cancelling stops the answer, it does
/// not erase what the user has already read.
class GenerationControl {
  int _id = 0;
  bool _cancelled = false;

  int get id => _id;
  bool get cancelled => _cancelled;

  /// Start a turn and return its token.
  int begin() {
    _cancelled = false;
    return ++_id;
  }

  /// Stop the current turn. Any token handed out before this is now stale.
  void cancel() {
    _cancelled = true;
    _id++;
  }

  /// Whether [token] still belongs to the turn the user is waiting on.
  bool isCurrent(int token) => !_cancelled && token == _id;
}
