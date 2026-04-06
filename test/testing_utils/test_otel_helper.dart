// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

// Test helper for initializing FlutterOTel without gRPC exporters or timers.
//
// In test environments (especially `testWidgets` which uses FakeAsync),
// gRPC exporters create real socket connections and timers that conflict
// with the fake async zone. This helper uses ConsoleExporter with a
// simple span processor that has no timers.

import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart';

/// Initializes FlutterOTel for widget tests without gRPC connections or timers.
///
/// This avoids the FakeAsync timer conflicts that occur when gRPC exporters
/// try to establish real socket connections during `testWidgets`.
Future<void> initializeFlutterOTelForTest({
  String serviceName = 'test-service',
  String serviceVersion = '1.0.0',
  bool enableLogs = false,
  bool enableAutoLogEvents = false,
  bool enableMetrics = false,
  LogRecordProcessor? logRecordProcessor,
  CommonAttributesFunction? commonAttributesFunction,
}) async {
  await FlutterOTel.initialize(
    endpoint: 'http://localhost:4317',
    serviceName: serviceName,
    serviceVersion: serviceVersion,
    spanProcessor: SimpleSpanProcessor(ConsoleExporter()),
    enableMetrics: enableMetrics,
    enableLogs: enableLogs,
    enableAutoLogEvents: enableAutoLogEvents,
    logRecordProcessor: logRecordProcessor,
    flushTracesInterval: null, // No periodic flush timer in tests
    detectPlatformResources: false,
    commonAttributesFunction: commonAttributesFunction,
  );
}
