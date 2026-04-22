// Licensed under the Apache License, Version 2.0

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

/// RUM session metadata (parity with native `SessionMetadata`).
///
/// [sessionCreationDateEpoch] is seconds since the Unix epoch, matching Swift
/// `Date.timeIntervalSince1970`.
class SessionMetadata {
  const SessionMetadata({
    required this.sessionId,
    required this.sessionCreationDateEpoch,
  });

  final String sessionId;

  /// Seconds since 1970-01-01 UTC.
  final double sessionCreationDateEpoch;
}

/// When a new session is created (aligned with the iOS `SessionManager`):
///
/// 1. **Idle timeout** — [checkIdleTime] is invoked (e.g. from the replay
///    capture loop). If time since the last recorded activity exceeds
///    [idleInterval], a new session is started.
///
/// 2. **Max session duration** — [getSessionMetadata] rotates the session when
///    the user is not idle and [maxSessionDuration] has elapsed since
///    [SessionMetadata.sessionCreationDateEpoch] (default four hours).
///
/// 3. **Explicit** — call [setupSessionMetadata] (or [reset] / [shutdown] flows).
///
/// **Activity** — Call [updateActivityTime] when the app becomes active
/// (handled automatically when [registerWidgetsBindingObserver] is true) and
/// on user gestures via [notifyUserAction] (wired from `FlutterOTel` when
/// interactions are recorded).
class SessionManager with WidgetsBindingObserver {
  SessionManager({
    this.sessionChangedCallback,
    this.sessionEndedCallback,
    this.idleInterval = const Duration(minutes: 5),
    this.maxSessionDuration = const Duration(hours: 4),
    this.registerWidgetsBindingObserver = true,
  }) {
    _setupSessionMetadata();
    if (registerWidgetsBindingObserver) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  /// Fired whenever [sessionMetadata] is replaced with a new session id.
  void Function(String sessionId)? sessionChangedCallback;

  /// Fired before a session is rotated due to idle return, max duration, or
  /// [checkIdleTime].
  void Function()? sessionEndedCallback;

  /// No user activity for this long counts as idle (default five minutes).
  final Duration idleInterval;

  /// Hard cap on session wall-clock age while active (default four hours).
  final Duration maxSessionDuration;

  final bool registerWidgetsBindingObserver;

  SessionMetadata? _sessionMetadata;
  SessionMetadata? _prevSessionMetadata;

  DateTime _lastActivity = DateTime.now();

  int _errorCount = 0;
  int _clickCount = 0;

  /// Last snapshot-related event time (reserved for parity with native SDK).
  DateTime? lastSnapshotEventTime;

  /// Whether replay has been active for the current session (set by host SDK).
  bool hasRecording = false;

  SessionMetadata? get sessionMetadata => _sessionMetadata;

  SessionMetadata? get prevSessionMetadata => _prevSessionMetadata;

  /// Seconds since [_lastActivity].
  bool get isIdle {
    final elapsed = DateTime.now().difference(_lastActivity);
    return elapsed > idleInterval;
  }

  /// Same semantics as Swift `getSessionMetadata()`.
  SessionMetadata? getSessionMetadata() {
    final creation = _sessionMetadata?.sessionCreationDateEpoch;
    if (creation != null &&
        creation > 0 &&
        !isIdle &&
        _hasMaxSessionDurationElapsed(creation)) {
      sessionEndedCallback?.call();
      _setupSessionMetadata();
    }
    return _sessionMetadata;
  }

  bool doesSessionHasRecording() => hasRecording;

  void incrementErrorCounter() => _errorCount++;

  void decrementErrorCounter() {
    if (_errorCount > 0) _errorCount--;
  }

  void incrementClickCounter() => _clickCount++;

  SessionMetadata? getPrevSessionMetadata() => _prevSessionMetadata;

  int getErrorCount() => _errorCount;

  int getClickCount() => _clickCount;

  /// Swift `shutdown` — clears metadata and counters.
  void shutdown() {
    _sessionMetadata = SessionMetadata(
      sessionId: '',
      sessionCreationDateEpoch: 0,
    );
    reset();
  }

  void reset() {
    _errorCount = 0;
    _clickCount = 0;
    hasRecording = false;
  }

  /// Call when the app returns to the foreground (`UIApplication` active).
  void updateActivityTime() {
    if (isIdle) {
      if (kDebugMode) {
        debugPrint('[SDK] transitioning from idle to active state');
      }
      sessionEndedCallback?.call();
      _setupSessionMetadata();
    }
    _lastActivity = DateTime.now();
  }

  /// Maps to the native user-action notification (tap / tracked interaction).
  void notifyUserAction() => updateActivityTime();

  /// Invoked periodically while replay is running; starts a new session after
  /// prolonged inactivity.
  void checkIdleTime() {
    if (DateTime.now().difference(_lastActivity) > idleInterval) {
      sessionEndedCallback?.call();
      _setupSessionMetadata();
      _lastActivity = DateTime.now();
    }
  }

  void setupSessionMetadata() => _setupSessionMetadata();

  void _setupSessionMetadata() {
    _prevSessionMetadata = _sessionMetadata;
    final id = const Uuid().v4().replaceAll('-', '').toLowerCase();
    final now = DateTime.now();
    _sessionMetadata = SessionMetadata(
      sessionId: id,
      sessionCreationDateEpoch: now.millisecondsSinceEpoch / 1000.0,
    );
    final sid = _sessionMetadata!.sessionId;
    sessionChangedCallback?.call(sid);
  }

  bool _hasMaxSessionDurationElapsed(double epochSeconds) {
    if (epochSeconds <= 0) return false;
    final created = DateTime.fromMillisecondsSinceEpoch(
      (epochSeconds * 1000).round(),
      isUtc: true,
    );
    return DateTime.now().difference(created) >= maxSessionDuration;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      updateActivityTime();
    }
  }

  void dispose() {
    if (registerWidgetsBindingObserver) {
      WidgetsBinding.instance.removeObserver(this);
    }
  }
}
