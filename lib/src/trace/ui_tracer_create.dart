// Licensed under the Apache License, Version 2.0

part of 'ui_tracer.dart';

/// Factory for creating UITracer instances
class UITracerCreate {
  static UITracer create({
    required sdk.Tracer delegate,
    required sdk.TracerProvider provider,
    sdk.Sampler? sampler,
  }) {
    return UITracer._(delegate: delegate, provider: provider, sampler: sampler);
  }
}
