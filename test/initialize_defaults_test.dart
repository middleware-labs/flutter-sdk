// Licensed under the Apache License, Version 2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:middleware_flutter_opentelemetry/middleware_flutter_opentelemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await FlutterOTel.reset();
  });

  // Regression: without a spanProcessor or commonAttributesFunction,
  // initialize() threw "Null check operator used on a null value" because the
  // default was assigned to the parameter but read from the static field.
  test('initialize builds the default span processor without a '
      'commonAttributesFunction', () async {
    await FlutterOTel.initialize(
      endpoint: 'http://localhost:4318',
      serviceName: 'defaults-test',
      enableMetrics: false,
      enableLogs: false,
      enableSessionRecording: false,
      flushTracesInterval: null,
      detectPlatformResources: false,
    );

    expect(FlutterOTel.commonAttributesFunction, isNotNull);
  });
}
