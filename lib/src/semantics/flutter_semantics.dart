// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

// ignore_for_file: public_member_api_docs

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';

/// Flutter-specific semantic conventions for OpenTelemetry.
///
/// These enums define attribute keys used by Flutterrific OpenTelemetry
/// for Flutter-specific instrumentation that does not yet have standardized
/// OTel semantic conventions.
///
/// **Spec Proposal Status**: These are proposed additions to the OpenTelemetry
/// Client Instrumentation specification. They follow the emerging OTel client
/// RUM conventions and are candidates for upstream contribution. As the OTel
/// client spec matures, these may be replaced by official semantic conventions.
///
/// See also:
/// - [OTel Client Instrumentation](https://opentelemetry.io/docs/specs/semconv/general/events/)
/// - [OTel RUM Conventions](https://opentelemetry.io/docs/specs/semconv/rum/)

/// Proposed semantic conventions for Flutter error context attributes.
///
/// These extend the standard OTel `error.*` and `exception.*` conventions
/// with Flutter-specific context about where errors occur in the widget tree
/// and build pipeline.
///
/// Spec proposal: These attributes provide critical debugging context for
/// Flutter's unique widget-based error reporting that has no equivalent in
/// web or native RUM specs.
enum FlutterErrorSemantics implements OTelSemantic {
  /// The logical context in which the error occurred (e.g. 'widget_build',
  /// 'navigation', 'lifecycle'). Complements `error.type` and `error.message`.
  errorContext('error.context'),

  /// The widget class name where the error occurred, extracted from
  /// Flutter's `FlutterErrorDetails.context`.
  errorWidget('error.widget'),

  /// The widget context description from `FlutterErrorDetails.context`,
  /// typically a human-readable string like "while building MyWidget".
  errorWidgetContext('error.widget_context'),

  /// The source code location where the error was reported, if available.
  errorLocation('error.location');

  @override
  final String key;

  @override
  String toString() => key;

  const FlutterErrorSemantics(this.key);
}

/// Proposed semantic conventions for Flutter performance measurement attributes.
///
/// These extend the standard OTel `performance.*` conventions with
/// Flutter-specific performance instrumentation for frame rendering,
/// widget builds, and custom performance measurements.
///
/// Spec proposal: Flutter's rendering pipeline (build/layout/paint) produces
/// performance metrics that have no direct equivalent in web or native
/// platform instrumentation.
enum FlutterPerformanceSemantics implements OTelSemantic {
  /// The name of the performance metric being recorded.
  metricName('perf.metric.name'),

  /// Duration of the performance measurement in milliseconds.
  durationMs('perf.duration_ms');

  @override
  final String key;

  @override
  String toString() => key;

  const FlutterPerformanceSemantics(this.key);
}

/// Proposed semantic conventions for Flutter UI element type attributes.
///
/// Spec proposal: Client instrumentation needs a way to identify the type
/// of UI element generating telemetry (screen, dialog, bottom sheet, etc.).
enum FlutterUISemantics implements OTelSemantic {
  /// The type of UI element (e.g. 'screen', 'dialog', 'bottom_sheet').
  uiType('ui.type');

  @override
  final String key;

  @override
  String toString() => key;

  const FlutterUISemantics(this.key);
}

/// Proposed semantic conventions for Flutter scroll interaction attributes.
///
/// Spec proposal: Scroll position tracking is common in client RUM for
/// understanding user engagement depth and content visibility.
enum FlutterScrollSemantics implements OTelSemantic {
  /// The current scroll position in logical pixels.
  scrollPosition('scroll.position');

  @override
  final String key;

  @override
  String toString() => key;

  const FlutterScrollSemantics(this.key);
}

/// Proposed semantic conventions for Flutter navigation redirect attributes.
///
/// Spec proposal: Client-side routing frameworks (GoRouter, auto_route)
/// perform redirects that need distinct telemetry from standard navigation.
enum FlutterRedirectSemantics implements OTelSemantic {
  /// The destination path of a navigation redirect.
  redirectTo('redirect.to');

  @override
  final String key;

  @override
  String toString() => key;

  const FlutterRedirectSemantics(this.key);
}

/// Proposed semantic conventions for Flutter lifecycle metric attributes.
///
/// These complement `AppLifecycleSemantics` from the API with metric-specific
/// keys used when recording lifecycle state changes as metric data points.
///
/// Spec proposal: Lifecycle metrics need their own attribute namespace to
/// distinguish metric-context attributes from trace-context attributes.
enum FlutterLifecycleMetricSemantics implements OTelSemantic {
  /// The lifecycle state for metric recording context.
  lifecycleState('lifecycle.state');

  @override
  final String key;

  @override
  String toString() => key;

  const FlutterLifecycleMetricSemantics(this.key);
}

/// Proposed semantic conventions for Flutter route metric attributes.
///
/// These complement `NavigationSemantics` from the API with metric-specific
/// route keys used when recording navigation as metric data points.
///
/// Spec proposal: Route change metrics need simplified attribute keys
/// distinct from the full navigation trace semantics.
enum FlutterRouteMetricSemantics implements OTelSemantic {
  /// Route name in metric context.
  routeName('route.name'),

  /// Route action in metric context (push, pop, replace, etc.).
  routeAction('route.action'),

  /// The source route in a navigation metric.
  navigationFromRoute('navigation.from_route'),

  /// The destination route in a navigation metric.
  navigationToRoute('navigation.to_route');

  @override
  final String key;

  @override
  String toString() => key;

  const FlutterRouteMetricSemantics(this.key);
}

/// Proposed semantic conventions for OTel Event names used by Flutterrific.
///
/// These follow the emerging OTel client instrumentation event naming
/// conventions. Event names identify the class/type of structured log event.
///
/// Spec proposal: These event names follow the `device.app.*` and
/// `browser.*` naming patterns from the draft OTel client RUM spec.
enum FlutterEventNames implements OTelSemantic {
  /// App lifecycle state change event.
  appLifecycle('device.app.lifecycle'),

  /// App error event.
  appError('device.app.error'),

  /// Navigation/route change event.
  navigation('browser.navigation');

  @override
  final String key;

  @override
  String toString() => key;

  const FlutterEventNames(this.key);
}
