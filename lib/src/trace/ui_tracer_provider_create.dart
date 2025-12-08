// Licensed under the Apache License, Version 2.0

part of 'ui_tracer_provider.dart';

/// Factory for creating UITracer instances
class UITracerProviderCreate {
  static UITracerProvider create({required TracerProvider delegate}) {
    return UITracerProvider._(delegate: delegate);
  }
}
