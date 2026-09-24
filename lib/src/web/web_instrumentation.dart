// Licensed under the Apache License, Version 2.0

import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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

  static WebInstrumentationOptions _options = WebInstrumentationOptions.disabled;
  static RageClickDetector? _rageClick;

  static bool get isActive => kIsWeb && _options.enabled;

  /// True for crawler / headless user agents (always false off the web).
  static bool get isBotTraffic => kIsWeb && impl.isBotTraffic();

  /// Browser name/version/user agent/origin for the OTel resource.
  static Map<String, Object> resourceAttributes() =>
      kIsWeb ? impl.browserResourceAttributes() : const {};

  static void enable(WebInstrumentationOptions options) {
    if (!kIsWeb) return;
    _options = options;
    _rageClick = options.rageClick ? RageClickDetector() : null;
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
    _rageClick = null;
    InteractionContext.clear();
  }

  /// Browser-SDK click attributes for an auto-captured tap at logical
  /// ([x], [y]) — the same keys the web click heatmap reads (Flutter logical
  /// pixels are CSS pixels on the web). Empty off the web.
  static Map<String, Object> tapAttributes({
    required double x,
    required double y,
    required String route,
    required String targetElement,
    PointerDeviceKind? pointerKind,
  }) {
    if (!isActive) return const {};
    final attrs = <String, Object>{
      'x': x,
      'y': y,
      'pageX': x,
      'pageY': y,
      'target_element': targetElement,
      'target_xpath': '$route/$targetElement',
      'pointer.type': switch (pointerKind) {
        PointerDeviceKind.touch => 'touch',
        PointerDeviceKind.stylus || PointerDeviceKind.invertedStylus => 'pen',
        _ => 'mouse',
      },
    };
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      attrs['viewport.width'] = size.width;
      attrs['viewport.height'] = size.height;
    } catch (_) {}
    if (_rageClick?.isRageClick(x, y) ?? false) {
      attrs['frustration.type'] = 'rage_click';
    }
    return attrs;
  }

  /// Makes network requests starting within a second of [startedAt]
  /// attributable to the interaction [span] (`interaction.trace_id` /
  /// `span_id` / `name`).
  static void onInteraction(
    APISpan? span,
    String name, {
    DateTime? startedAt,
  }) {
    if (!isActive || span == null) return;
    InteractionContext.setActiveInteraction(
      span.spanContext.traceId.hexString,
      span.spanContext.spanId.hexString,
      name: name,
      startedAt: startedAt,
    );
  }
}
