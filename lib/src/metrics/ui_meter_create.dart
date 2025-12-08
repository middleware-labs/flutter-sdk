// Licensed under the Apache License, Version 2.0

part of 'ui_meter.dart';

/// Factory for creating UITracer instances
class UIMeterCreate {
  static UIMeter create({required Meter delegate}) {
    return UIMeter._(delegate);
  }
}
