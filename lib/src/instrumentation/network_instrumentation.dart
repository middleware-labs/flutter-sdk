// Licensed under the Apache License, Version 2.0

import 'package:meta/meta.dart' show internal;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    show HttpInstrumentationConfig, SpanProcessor;

import '../common/network_capture.dart';
import 'network_instrumentation_stub.dart'
    if (dart.library.io) 'network_instrumentation_io.dart'
    as impl;

/// Automatic HTTP spans on Android, iOS and desktop. Started by
/// `FlutterOTel.initialize(enableAutomaticNetworkInstrumentation: ...)`.
///
/// Every Dart HTTP client on those platforms (`package:http`, `dio`,
/// `NetworkImage`, `WebSocket.connect`, anything else built on `dart:io`'s
/// `HttpClient`) is traced and carries trace headers without being wrapped.
/// Flutter web is covered by `WebInstrumentationOptions.network` instead, so
/// this is a no-op there.
class NetworkInstrumentation {
  NetworkInstrumentation._();

  /// Whether requests are currently being traced.
  static bool get isActive => impl.isActive;

  /// Starts tracing with [config].
  ///
  /// [captureNetworkHeaders] records every request and response header (or
  /// only `config.capturedHeaders` when the app changed that allowlist) as
  /// `http.request.header.<name>` / `http.response.header.<name>`.
  /// [captureResponseBodies] records JSON and plain-text response bodies, up
  /// to 64 KiB, as `http.response.body`. [ignoreHeaders] (case-insensitive)
  /// are never recorded. All off by default; request bodies are never
  /// recorded.
  static void enable(
    HttpInstrumentationConfig config, {
    bool captureNetworkHeaders = false,
    bool captureResponseBodies = false,
    Set<String> ignoreHeaders = const <String>{},
  }) => impl.enable(
    config,
    capture: NetworkCapture(
      headers: captureNetworkHeaders,
      responseBodies: captureResponseBodies,
      ignoreHeaders: ignoreHeaders,
    ),
  );

  static void disable() => impl.disable();

  /// Wraps the SDK's span processor so requests already traced by
  /// `OTelHttpClient` / `OTelDioInterceptor` aren't traced twice. Called by
  /// `FlutterOTel.initialize` before the tracer provider is built.
  @internal
  static SpanProcessor trackManualSpans(SpanProcessor processor) =>
      impl.trackManualSpans(processor);
}
