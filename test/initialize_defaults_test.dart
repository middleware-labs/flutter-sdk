// Licensed under the Apache License, Version 2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:middleware_flutter_opentelemetry/middleware_flutter_opentelemetry.dart';
import 'package:middleware_flutter_opentelemetry/src/util/sdk_version.dart';

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

  test('initialize reports the Flutter SDK version on the resource', () async {
    await FlutterOTel.initialize(
      endpoint: 'http://localhost:4318',
      serviceName: 'defaults-test',
      enableMetrics: false,
      enableLogs: false,
      enableSessionRecording: false,
      flushTracesInterval: null,
      detectPlatformResources: false,
    );

    final resource = OTel.tracerProvider().resource!;
    expect(resource.attributes.getString('mw.rum.sdk.version'),
        middlewareFlutterSdkVersion);
  });
}
