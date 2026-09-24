// Licensed under the Apache License, Version 2.0

// Span and log helpers shared by the Flutter web instrumentations. Pure Dart
// (no browser APIs) so it compiles on every platform.

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    as sdk;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

import '../flutterrific_otel.dart';
import '../trace/ui_tracer.dart';
import 'web_utils.dart';

/// Converts a performance-timeline timestamp (ms since `timeOrigin`) to wall
/// clock time.
DateTime perfToDateTime(double timeOrigin, double perfMs) =>
    DateTime.fromMicrosecondsSinceEpoch(((timeOrigin + perfMs) * 1000).round());

class WebTelemetry {
  WebTelemetry._();

  static UITracer _tracer(String scope) =>
      FlutterOTel.tracerProvider.getTracer(scope) as UITracer;

  /// Starts a span named [name] on the [scope] tracer.
  ///
  /// With [startTime] the span is backdated, which is what timeline-derived
  /// spans (resources, long tasks, web vitals) need; the SDK's `startSpan`
  /// always starts "now". Without [parent] the span is a trace root.
  static sdk.Span startSpan(
    String name, {
    String scope = 'flutter-web',
    DateTime? startTime,
    APISpan? parent,
    Map<String, Object>? attributes,
    SpanKind kind = SpanKind.internal,
  }) {
    final tracer = _tracer(scope);
    final attrs = attributes == null ? null : _clean(attributes).toAttributes();
    if (startTime == null) {
      return tracer.startSpan(
        name,
        context: Context.root,
        parentSpan: parent,
        kind: kind,
        attributes: attrs,
      );
    }
    final parentContext = parent?.spanContext;
    final spanContext = sdk.OTel.spanContext(
      traceId: parentContext?.traceId ?? sdk.OTel.traceId(),
      spanId: sdk.OTel.spanId(),
      parentSpanId: parentContext?.spanId ?? sdk.OTel.spanIdInvalid(),
      traceFlags: sdk.OTel.traceFlags(TraceFlags.SAMPLED_FLAG),
    );
    final span = tracer.createSpan(
      name: name,
      spanContext: spanContext,
      parentSpan: parent,
      kind: kind,
      attributes: attrs,
      startTime: startTime,
      context: Context.root,
    );
    // createSpan skips the processors' onStart; run it so backdated spans get
    // the same session/global attributes as every other span.
    for (final processor in FlutterOTel.tracerProvider.spanProcessors) {
      try {
        processor.onStart(span, Context.root);
      } catch (_) {
        // a failing decorator must not lose the span
      }
    }
    return span;
  }

  /// Sets [attributes] on [span], skipping values OTel can't carry.
  static void setAttributes(APISpan span, Map<String, Object?> attributes) {
    final clean = _clean(attributes);
    if (clean.isNotEmpty) span.addAttributes(clean.toAttributes());
  }

  /// Adds a timeline marker as a span event (upstream `addSpanNetworkEvent`).
  static void addTimelineEvent(
    APISpan span,
    String name,
    double timeOrigin,
    double perfMs,
  ) {
    if (perfMs <= 0) return;
    span.addEvent(
      sdk.OTel.spanEvent(
        name,
        sdk.OTel.attributes(),
        perfToDateTime(timeOrigin, perfMs),
      ),
    );
  }

  /// Emits an OTel log record linked to [span]'s trace.
  static void log({
    required String loggerName,
    required Severity severity,
    required String body,
    Map<String, Object?> attributes = const {},
    APISpan? span,
  }) {
    try {
      FlutterOTel.logger(loggerName).emit(
        severityNumber: severity,
        severityText: severity.name.toUpperCase(),
        body: body,
        attributes: _clean(attributes).toAttributes(),
        context: span == null ? null : Context.root.withSpan(span),
      );
    } catch (_) {
      // logs pipeline may be disabled
    }
  }

  /// Records a browser error the way the browser SDK does: an `error-trace`
  /// span named after the message (status ERROR, `exception` event with the
  /// parsed JS stack) plus an ERROR log record in the same trace.
  static void recordBrowserError({
    required String errorType,
    required String message,
    String? name,
    String? stack,
    String? object,
    Map<String, Object?> extraAttributes = const {},
  }) {
    final msg = limitLen(message, messageLimit);
    final attrs = <String, Object?>{
      'type': 'error',
      'event.type': 'error',
      'error.type': errorType,
      'level': 'error',
      'error.name': name,
      'error.message': msg,
      'error.object': object ?? name ?? 'Error',
      ...extraAttributes,
    };
    final span = startSpan(
      msg.isEmpty ? errorType : msg,
      scope: 'error-trace',
      attributes: _clean(attrs),
    );
    if (stack != null && stack.isNotEmpty) {
      final frames = parseJsStack(stack);
      final limited = limitLen(stack, stackLimit);
      final stackAttrs = <String, Object?>{
        'error.stack': limited,
        if (frames.isNotEmpty) 'error.structuredStack': safeJson(frames),
      };
      setAttributes(span, stackAttrs);
      attrs.addAll(stackAttrs);
      span.addEventNow(
        'exception',
        _clean({
          'exception.type': name,
          'exception.message': msg,
          'exception.stacktrace': stack,
          'exception.stack_details': safeJson(exceptionStackFrames(frames)),
        }).toAttributes(),
      );
    }
    span.setStatus(SpanStatusCode.Error, msg);
    span.end();
    FlutterOTel.sessionManager?.incrementErrorCounter();
    log(
      loggerName: 'browser.errors',
      severity: Severity.ERROR,
      body: msg,
      attributes: attrs,
      span: span,
    );
  }

  static Map<String, Object> _clean(Map<String, Object?> input) {
    final out = <String, Object>{};
    input.forEach((key, value) {
      if (value == null) return;
      if (value is double && (value.isNaN || value.isInfinite)) return;
      if (value is String ||
          value is bool ||
          value is int ||
          value is double ||
          value is List<String> ||
          value is List<int> ||
          value is List<double> ||
          value is List<bool>) {
        out[key] = value;
      } else {
        out[key] = value.toString();
      }
    });
    return out;
  }
}
