// Licensed under the Apache License, Version 2.0

import 'package:meta/meta.dart' show internal;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    show TracePropagationFormat;

import '../common/network_capture.dart';

// One enum for web and mobile: the web options take it here, and the mobile
// `HttpInstrumentationConfig` (OTelHttpClient / OTelDioInterceptor) takes the
// same type.
export 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    show TracePropagationFormat;

/// Browser instrumentation for Flutter web, mirroring the Middleware browser
/// SDK (`@middleware.io/browser`). Ignored on every other platform.
///
/// Pass it to `FlutterOTel.initialize(webInstrumentation: ...)`. Every
/// instrumentation is on by default except [captureNetworkHeaders] and
/// [captureResponseBodies], which record request/response headers and
/// response bodies (credentials, personal data).
class WebInstrumentationOptions {
  const WebInstrumentationOptions({
    this.enabled = true,
    this.documentLoad = true,
    this.network = true,
    this.captureNetworkHeaders,
    this.captureResponseBodies,
    @Deprecated('Use captureNetworkHeaders and captureResponseBodies')
    this.advanceNetworkCapture = false,
    this.ignoreHeaders = const <String>{},
    this.ignoreUrls = const <Pattern>[],
    this.tracePropagationTargets = const <Pattern>[],
    this.tracePropagationFormat = TracePropagationFormat.all,
    this.longTask = true,
    this.webVitals = true,
    this.pageTracking = true,
    this.errors = true,
    this.console = true,
    this.consoleRateLimit = 100,
    this.websocket = true,
    this.rageClick = true,
    this.blockBotTraffic = true,
  });

  /// Master switch for all browser instrumentation.
  final bool enabled;

  /// `documentLoad` / `documentFetch` / `resourceFetch` spans built from the
  /// Navigation and Resource Timing buffers, plus resource spans for anything
  /// the page loads later (fonts, images, scripts).
  final bool documentLoad;

  /// `fetch` and `XMLHttpRequest` spans. Patching happens at the browser level,
  /// so every Dart HTTP client (`package:http`, `dio`, Flutter asset loading)
  /// is covered without wrapping it.
  final bool network;

  /// Record request and response headers on network spans as
  /// `http.request.header.<name>` / `http.response.header.<name>` (lowercase,
  /// `-` replaced with `_`), and read `Server-Timing` trace links from XHR
  /// responses. `x-access-token` is masked; [ignoreHeaders] are skipped.
  ///
  /// When null (the default) it follows the deprecated
  /// [advanceNetworkCapture] if that is on, otherwise
  /// `FlutterOTel.initialize(captureNetworkHeaders: ...)` (off by default).
  final bool? captureNetworkHeaders;

  /// Record response bodies as `http.response.body` when the response's
  /// `Content-Type` is `application/json`, `*+json` or `text/plain` (capped at
  /// 8 KB). Request bodies are never recorded.
  ///
  /// When null (the default) it follows the deprecated
  /// [advanceNetworkCapture] if that is on, otherwise
  /// `FlutterOTel.initialize(captureResponseBodies: ...)` (off by default).
  final bool? captureResponseBodies;

  /// Turns on both [captureNetworkHeaders] and [captureResponseBodies] when
  /// they are left unset.
  @Deprecated('Use captureNetworkHeaders and captureResponseBodies')
  final bool advanceNetworkCapture;

  /// Header names (case-insensitive) never captured by
  /// [captureNetworkHeaders], in addition to
  /// `FlutterOTel.initialize(ignoreHeaders: ...)`.
  final Set<String> ignoreHeaders;

  /// URLs (RegExp or exact String) that are never instrumented. The SDK's own
  /// `/v1/traces`, `/v1/metrics` and `/v1/logs` exports are always ignored.
  final List<Pattern> ignoreUrls;

  /// Cross-origin URLs that receive trace headers. Same-origin requests always
  /// do. Add only backends whose CORS policy allows `traceparent` (and `b3`),
  /// otherwise the browser rejects the preflight. Use `[RegExp('.*')]` for the
  /// browser SDK's propagate-everywhere behaviour.
  final List<Pattern> tracePropagationTargets;

  final TracePropagationFormat tracePropagationFormat;

  /// Spans for main-thread tasks over 50ms (`longtask` entries).
  final bool longTask;

  /// LCP, FCP, CLS, INP and TTFB spans under a `webvitals` parent.
  final bool webVitals;

  /// `pageview` spans on URL changes (history API, popstate, hashchange),
  /// `pageleave` on tab hide and `pagehide` on unload.
  final bool pageTracking;

  /// Uncaught JS errors, unhandled promise rejections, failed resource loads
  /// and `console.error`, as error spans plus log records.
  final bool errors;

  /// `console.log/info/warn/debug` calls from JavaScript as log records.
  /// Dart `print` / `debugPrint` output is never captured here (use
  /// `logPrint`), which keeps the SDK from capturing its own diagnostics.
  final bool console;

  /// Console messages captured per second before the rest are dropped (a
  /// summary record reports how many). 0 disables the limit.
  final int consoleRateLimit;

  /// `WebSocket` connect/send/onmessage spans (off by default in the browser
  /// SDK; on here).
  final bool websocket;

  /// Tag rapid repeated taps with `frustration.type=rage_click` (requires
  /// `enableAutomaticUserInteractions`).
  final bool rageClick;

  /// Skip all telemetry for crawler / headless user agents.
  final bool blockBotTraffic;

  static const WebInstrumentationOptions disabled = WebInstrumentationOptions(
    enabled: false,
  );

  /// Header/body capture for the browser: each flag set here wins, then the
  /// deprecated [advanceNetworkCapture], then the app-wide [defaults] from
  /// `FlutterOTel.initialize`. [ignoreHeaders] add to the defaults'.
  @internal
  NetworkCapture resolveNetworkCapture(NetworkCapture defaults) {
    // ignore: deprecated_member_use_from_same_package
    final legacy = advanceNetworkCapture ? true : null;
    return NetworkCapture(
      headers: captureNetworkHeaders ?? legacy ?? defaults.headers,
      responseBodies:
          captureResponseBodies ?? legacy ?? defaults.responseBodies,
      ignoreHeaders: {...defaults.ignoreHeaders, ...ignoreHeaders},
    );
  }
}
