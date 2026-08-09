import 'dart:async';

class AgentCancellationToken {
  bool _cancelled = false;
  final Completer<void> _cancelledCompleter = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _cancelledCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelledCompleter.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) throw const AgentCancelledException();
  }
}

class AgentCancelledException implements Exception {
  const AgentCancelledException();
  @override
  String toString() => 'Agent request cancelled';
}
