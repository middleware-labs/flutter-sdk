// Licensed under the Apache License, Version 2.0

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:middleware_flutter_opentelemetry/middleware_flutter_opentelemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(MiddlewareNativeBridge.channel, null);
    MiddlewareNativeBridge.resetForTest();
  });

  group('MiddlewareNativeBridge', () {
    test('initNativeSdk sends the full config payload', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(MiddlewareNativeBridge.channel,
          (call) async {
        received = call;
        return <Object?, Object?>{
          'initialized': true,
          'appVersion': '1.2.3',
          'osVersion': '15',
          'deviceModel': 'Pixel',
        };
      });

      final info = await MiddlewareNativeBridge.initNativeSdk(
        target: 'https://example.middleware.io',
        accountKey: 'token',
        serviceName: 'svc',
        projectName: 'svc',
        deploymentEnvironment: 'dev',
        sessionRecording: true,
        disableSessionRecordingV3: false,
        sessionSamplingRatio: 1.0,
        recordingOptions: const {'frequency': 'standard'},
      );

      expect(received?.method, 'initNativeSdk');
      final args = received!.arguments as Map<Object?, Object?>;
      expect(args['target'], 'https://example.middleware.io');
      expect(args['accountKey'], 'token');
      expect(args['serviceName'], 'svc');
      expect(args['projectName'], 'svc');
      expect(args['deploymentEnvironment'], 'dev');
      expect(args['sessionRecording'], true);
      expect(args['disableSessionRecordingV3'], false);
      expect(args['sessionSamplingRatio'], 1.0);
      expect(
          (args['recordingOptions'] as Map)['frequency'], 'standard');
      expect(info?['appVersion'], '1.2.3');
    });

    test('initNativeSdk returns null when native init fails', () async {
      messenger.setMockMethodCallHandler(MiddlewareNativeBridge.channel,
          (call) async => <Object?, Object?>{'initialized': false});
      final info = await MiddlewareNativeBridge.initNativeSdk(
        target: 't',
        accountKey: 'k',
        serviceName: 's',
        projectName: 'p',
      );
      expect(info, isNull);
    });

    test('setSessionId sends the id and start time as double ms', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(MiddlewareNativeBridge.channel,
          (call) async {
        received = call;
        return null;
      });

      await MiddlewareNativeBridge.setSessionId(
          'cafebabecafebabecafebabecafebabe', 1750000000000);

      expect(received?.method, 'setSessionId');
      final args = received!.arguments as Map<Object?, Object?>;
      expect(args['sessionId'], 'cafebabecafebabecafebabecafebabe');
      expect(args['startTimeMs'], 1750000000000.0);
    });

    test('setScreenName sends the route name', () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(MiddlewareNativeBridge.channel,
          (call) async {
        received = call;
        return null;
      });

      await MiddlewareNativeBridge.setScreenName('HomeScreen');
      expect(received?.method, 'setScreenName');
      expect(received?.arguments, 'HomeScreen');
    });

    test('MissingPluginException latches to no-op', () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(MiddlewareNativeBridge.channel,
          (call) async {
        calls++;
        throw MissingPluginException();
      });

      await MiddlewareNativeBridge.setScreenName('a');
      await MiddlewareNativeBridge.setScreenName('b');
      await MiddlewareNativeBridge.setScreenName('c');

      // only the first call reaches the channel; the latch stops the rest
      expect(calls, 1);
    });

    test('PlatformException is swallowed', () async {
      messenger.setMockMethodCallHandler(MiddlewareNativeBridge.channel,
          (call) async {
        throw PlatformException(code: 'MW_INIT');
      });
      await expectLater(
          MiddlewareNativeBridge.setScreenName('x'), completes);
    });
  });

  group('RecordingOptions.toNativeMap', () {
    test('returns null when nothing native is configured', () {
      expect(const RecordingOptions().toNativeMap(), isNull);
    });

    test('maps enums and masks to the bridge shape', () {
      const options = RecordingOptions(
        frequency: NativeRecordingFrequency.high,
        quality: NativeRecordingQuality.standard,
        maskAllTextInputs: false,
        maskAllImages: true,
      );
      expect(options.toNativeMap(), {
        'frequency': 'high',
        'quality': 'standard',
        'maskAllTextInputs': false,
        'maskAllImages': true,
      });
    });
  });
}
