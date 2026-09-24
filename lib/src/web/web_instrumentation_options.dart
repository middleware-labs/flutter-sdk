// Licensed under the Apache License, Version 2.0

/// Trace-context header formats injected into instrumented requests.
enum TracePropagationFormat {
  /// W3C `traceparent` only.
  w3c,

  /// B3 single (`b3`) and multi (`X-B3-*`) headers.
  b3,

  /// W3C plus both B3 encodings (browser SDK default).
  all,
}

/// Browser instrumentation for Flutter web, mirroring the Middleware browser
/// SDK (`@middleware.io/browser`). Ignored on every other platform.
///
/// Pass it to `FlutterOTel.initialize(webInstrumentation: ...)`. Every
/// instrumentation is on by default except [websocket] and
/// [advanceNetworkCapture], matching the browser SDK's defaults.
class WebInstrumentationOptions {
  const WebInstrumentationOptions({
    this.enabled = true,
    this.documentLoad = true,
    this.network = true,
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
    this.websocket = false,
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

  /// Also capture request/response headers and bodies on network spans.
  /// Off by default: bodies may carry PII.
  final bool advanceNetworkCapture;

  /// Header names (case-insensitive) never captured by [advanceNetworkCapture].
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

  /// `console.log/info/warn/debug` as log records.
  final bool console;

  /// Console messages captured per second before the rest are dropped (a
  /// summary record reports how many). 0 disables the limit.
  final int consoleRateLimit;

  /// `WebSocket` connect/send/onmessage spans.
  final bool websocket;

  /// Tag rapid repeated taps with `frustration.type=rage_click` (requires
  /// `enableAutomaticUserInteractions`).
  final bool rageClick;

  /// Skip all telemetry for crawler / headless user agents.
  final bool blockBotTraffic;

  static const WebInstrumentationOptions disabled = WebInstrumentationOptions(
    enabled: false,
  );
}
