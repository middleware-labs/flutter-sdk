// Licensed under the Apache License, Version 2.0

import 'package:flutter/foundation.dart';
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

import 'web_instrumentation_options.dart';
import 'web_utils.dart';
import 'web_instrumentation_stub.dart'
    if (dart.library.js_interop) 'browser/web_instrumentation_web.dart'
    as impl;

/// Browser instrumentation for Flutter web (no-op on every other platform).
/// Started by `FlutterOTel.initialize`; see [WebInstrumentationOptions].
class WebInstrumentation {
  WebInstrumentation._();

  static WebInstrumentationOptions _options =
      WebInstrumentationOptions.disabled;

  static bool get isActive => kIsWeb && _options.enabled;

  /// True for crawler / headless user agents (always false off the web).
  static bool get isBotTraffic => kIsWeb && impl.isBotTraffic();

  /// Browser name/version/user agent/origin for the OTel resource.
  static Map<String, Object> resourceAttributes() =>
      kIsWeb ? impl.browserResourceAttributes() : const {};

  static void enable(WebInstrumentationOptions options) {
    if (!kIsWeb) return;
    _options = options;
    InteractionContext.clear();
    impl.enable(
      options,
      ignoreUrls: <Pattern>[...defaultIgnoredUrls, ...options.ignoreUrls],
    );
  }

  static void disable() {
    if (!kIsWeb) return;
    impl.disable();
    _options = WebInstrumentationOptions.disabled;
    InteractionContext.clear();
  }

  /// Rage-click tagging on taps: always off the web, and on the web unless
  /// [WebInstrumentationOptions.rageClick] turned it off.
  static bool get rageClickEnabled => !isActive || _options.rageClick;

  /// The page path (with a `#/` hash route) on the web; null elsewhere.
  static String? get pagePath => kIsWeb ? impl.pagePath() : null;

  /// Makes network requests starting within a second of [startedAt]
  /// attributable to the interaction [span] (`interaction.trace_id` /
  /// `span_id` / `name`).
  static void onInteraction(APISpan? span, String name, {DateTime? startedAt}) {
    if (!isActive || span == null) return;
    InteractionContext.setActiveInteraction(
      span.spanContext.traceId.hexString,
      span.spanContext.spanId.hexString,
      name: name,
      startedAt: startedAt,
    );
  }
}
