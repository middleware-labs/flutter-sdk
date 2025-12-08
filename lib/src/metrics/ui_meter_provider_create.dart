// Licensed under the Apache License, Version 2.0

part of 'ui_meter_provider.dart';

/// Factory methods for creating UIMeterProvider instances.
class UIMeterProviderCreate {
  /// Creates a new UIMeterProvider instance.
  static UIMeterProvider create(MeterProvider delegate) {
    return UIMeterProvider._(delegate);
  }
}
