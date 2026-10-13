// Licensed under the Apache License, Version 2.0

// Flutter web: fetch/XHR are patched by the web instrumentation instead.

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    show HttpInstrumentationConfig, SpanProcessor;

import '../common/network_capture.dart';

bool get isActive => false;

void enable(HttpInstrumentationConfig config, {NetworkCapture? capture}) {}

void disable() {}

SpanProcessor trackManualSpans(SpanProcessor processor) => processor;
