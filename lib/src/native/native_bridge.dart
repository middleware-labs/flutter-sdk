// Copyright © 2023 Middleware. Licensed under the Apache License, Version 2.0

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

/// Bridge to the Middleware native mobile SDKs (middleware-android /
/// MiddlewareRum iOS) over a MethodChannel.
///
/// The Dart layer owns tracing, the session id, and screen names; the native
/// SDKs provide session-linked crash reporting and the v3 session recording.
/// Every call degrades to a no-op on web/desktop, when the host app was built
/// without the plugin (MissingPluginException latch), or on platform errors —
/// the pure-Dart SDK keeps working regardless.
class MiddlewareNativeBridge {
  MiddlewareNativeBridge._();

  static const MethodChannel channel = MethodChannel(
    'middleware_flutter_opentelemetry',
  );

  /// True only on platforms where the plugin has a native implementation.
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Flips false on MissingPluginException (tests, add-to-app hosts built
  /// without the plugin) so later calls stop trying.
  static bool _available = true;

  @visibleForTesting
  static void resetForTest() {
    _available = true;
  }

  static Future<T?> _invoke<T>(String method, [dynamic arguments]) async {
    if (!isSupported || !_available) return null;
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      _available = false;
      return null;
    } on PlatformException catch (e) {
      if (OTelLog.isDebug()) {
        OTelLog.debug('MiddlewareNativeBridge.$method failed: $e');
      }
      return null;
    }
  }

  /// Initializes the native SDK. Returns native environment info
  /// ({initialized, appVersion, osVersion, deviceModel}) or null when the
  /// native SDK is unavailable or failed to start.
  static Future<Map<Object?, Object?>?> initNativeSdk({
    required String target,
    required String accountKey,
    required String serviceName,
    required String projectName,
    String? sessionId,
    int? sessionStartTimeMs,
    String? deploymentEnvironment,
    bool sessionRecording = true,
    bool disableSessionRecordingV3 = false,
    double? sessionSamplingRatio,
    Map<String, Object?>? recordingOptions,
    Map<String, Object?>? resourceAttributes,
    Map<String, Object?>? globalAttributes,
  }) async {
    final response = await _invoke<Map<Object?, Object?>>('initNativeSdk', {
      'target': target,
      'accountKey': accountKey,
      'serviceName': serviceName,
      'projectName': projectName,
      // Injected at native build time so native telemetry (AppStart, crash,
      // v3 recording) never starts under a native-generated session.
      if (sessionId != null) 'sessionId': sessionId,
      if (sessionStartTimeMs != null)
        'sessionStartTimeMs': sessionStartTimeMs.toDouble(),
      if (deploymentEnvironment != null)
        'deploymentEnvironment': deploymentEnvironment,
      'sessionRecording': sessionRecording,
      'disableSessionRecordingV3': disableSessionRecordingV3,
      if (sessionSamplingRatio != null)
        'sessionSamplingRatio': sessionSamplingRatio,
      if (recordingOptions != null) 'recordingOptions': recordingOptions,
      if (resourceAttributes != null) 'resourceAttributes': resourceAttributes,
      if (globalAttributes != null) 'globalAttributes': globalAttributes,
    });
    if (response == null || response['initialized'] != true) return null;
    return response;
  }

  /// Links the native SDK (and its v3 recording/crash reports) to the
  /// Dart-owned session.
  static Future<void> setSessionId(String sessionId, int startTimeMs) =>
      _invoke<void>('setSessionId', {
        'sessionId': sessionId,
        'startTimeMs': startTimeMs.toDouble(),
      });

  /// Pushes the Dart route name into the native screen-name store so native
  /// telemetry and the v3 replay carry it.
  static Future<void> setScreenName(String name) =>
      _invoke<void>('setScreenName', name);

  /// Test helper: crashes the native process (crash-reporting demo).
  static Future<void> nativeCrash() => _invoke<void>('nativeCrash');

  /// Test helper: blocks the Android main thread (ANR demo); no-op on iOS.
  static Future<void> nativeAnr() => _invoke<void>('nativeAnr');
}
