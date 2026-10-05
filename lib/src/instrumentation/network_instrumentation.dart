// Licensed under the Apache License, Version 2.0

import 'package:meta/meta.dart' show internal;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    show HttpInstrumentationConfig, SpanProcessor;

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

  static void enable(HttpInstrumentationConfig config) => impl.enable(config);

  static void disable() => impl.disable();

  /// Wraps the SDK's span processor so requests already traced by
  /// `OTelHttpClient` / `OTelDioInterceptor` aren't traced twice. Called by
  /// `FlutterOTel.initialize` before the tracer provider is built.
  @internal
  static SpanProcessor trackManualSpans(SpanProcessor processor) =>
      impl.trackManualSpans(processor);
}
