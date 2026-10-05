/// Fixed-window limits for traffic associated with one live WebSocket client.
///
/// This helper retains only the client identity and bounded counters. It does
/// not retain message contents, credentials, or action payloads.
class WebSocketRateLimiter {
  static const int defaultMaxMessagesPerWindow = 120;
  static const int defaultMaxActionRequestsPerWindow = 30;
  static const int defaultMaxViolations = 3;
  static const Duration defaultWindow = Duration(seconds: 1);

  WebSocketRateLimiter({
    int maxMessagesPerWindow = defaultMaxMessagesPerWindow,
    int maxActionRequestsPerWindow = defaultMaxActionRequestsPerWindow,
    Duration window = defaultWindow,
    int maxViolations = defaultMaxViolations,
    DateTime Function()? clock,
  }) : _maxMessagesPerWindow = maxMessagesPerWindow,
       _maxActionRequestsPerWindow = maxActionRequestsPerWindow,
       _window = window,
       _maxViolations = maxViolations,
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    if (maxMessagesPerWindow <= 0) {
      throw ArgumentError.value(
        maxMessagesPerWindow,
        'maxMessagesPerWindow',
        'must be greater than zero',
      );
    }
    if (maxActionRequestsPerWindow <= 0) {
      throw ArgumentError.value(
        maxActionRequestsPerWindow,
        'maxActionRequestsPerWindow',
        'must be greater than zero',
      );
    }
    if (window <= Duration.zero) {
      throw ArgumentError.value(window, 'window', 'must be greater than zero');
    }
    if (maxViolations <= 0) {
      throw ArgumentError.value(
        maxViolations,
        'maxViolations',
        'must be greater than zero',
      );
    }
  }

  final int _maxMessagesPerWindow;
  final int _maxActionRequestsPerWindow;
  final Duration _window;
  final int _maxViolations;
  final DateTime Function() _clock;
  final Map<Object, _WindowState> _messageWindows = <Object, _WindowState>{};
  final Map<Object, _WindowState> _actionWindows = <Object, _WindowState>{};

  int get maxMessagesPerWindow => _maxMessagesPerWindow;
  int get maxActionRequestsPerWindow => _maxActionRequestsPerWindow;
  Duration get window => _window;
  int get maxViolations => _maxViolations;

  WebSocketRateLimitResult allowMessage(Object client) =>
      _allow(_messageWindows, client, _maxMessagesPerWindow);

  WebSocketRateLimitResult allowAction(Object client) =>
      _allow(_actionWindows, client, _maxActionRequestsPerWindow);

  /// Removes all state for one disconnected client.
  void removeClient(Object client) {
    _messageWindows.remove(client);
    _actionWindows.remove(client);
  }

  /// Removes all client state, including state from a previous server run.
  void clear() {
    _messageWindows.clear();
    _actionWindows.clear();
  }

  WebSocketRateLimitResult _allow(
    Map<Object, _WindowState> windows,
    Object client,
    int limit,
  ) {
    final now = _clock().toUtc();
    var state = windows[client];
    if (state == null || !now.isBefore(state.windowStarted.add(_window))) {
      state = _WindowState(windowStarted: now);
      windows[client] = state;
    }

    if (state.count < limit) {
      state.count++;
      return const WebSocketRateLimitResult.allowed();
    }

    if (state.violations < _maxViolations) state.violations++;
    return WebSocketRateLimitResult.rejected(
      shouldClose: state.violations >= _maxViolations,
    );
  }
}

final class WebSocketRateLimitResult {
  const WebSocketRateLimitResult.allowed()
    : isAllowed = true,
      shouldClose = false;

  const WebSocketRateLimitResult.rejected({required this.shouldClose})
    : isAllowed = false;

  final bool isAllowed;
  final bool shouldClose;
}

final class _WindowState {
  _WindowState({required this.windowStarted});

  final DateTime windowStarted;
  int count = 0;
  int violations = 0;
}
