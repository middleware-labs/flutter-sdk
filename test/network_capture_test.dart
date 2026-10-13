// Licensed under the Apache License, Version 2.0

// ignore_for_file: deprecated_member_use_from_same_package

import 'package:flutter_test/flutter_test.dart';
import 'package:middleware_flutter_opentelemetry/middleware_flutter_opentelemetry.dart';
import 'package:middleware_flutter_opentelemetry/src/common/network_capture.dart';

void main() {
  group('captured body types', () {
    test('JSON, +json and text/plain', () {
      expect(isCapturedBodyType('application/json'), isTrue);
      expect(isCapturedBodyType('Application/JSON; charset=utf-8'), isTrue);
      expect(isCapturedBodyType('application/problem+json'), isTrue);
      expect(isCapturedBodyType('application/vnd.api+json; v=2'), isTrue);
      expect(isCapturedBodyType('text/plain;charset=UTF-8'), isTrue);
    });

    test('nothing else', () {
      expect(isCapturedBodyType(null), isFalse);
      expect(isCapturedBodyType(''), isFalse);
      expect(isCapturedBodyType('text/html'), isFalse);
      expect(isCapturedBodyType('text/x-component'), isFalse);
      expect(isCapturedBodyType('application/octet-stream'), isFalse);
      expect(isCapturedBodyType('image/svg+xml'), isFalse);
      expect(isJsonContentType('text/plain'), isFalse);
    });
  });

  group('header attributes', () {
    test('lowercase, - becomes _', () {
      expect(
        headerAttributeKey('request', 'X-Request-ID'),
        'http.request.header.x_request_id',
      );
    });

    test('x-access-token is masked', () {
      expect(headerAttributeValue('X-Access-Token', 'abc'), '********');
      expect(headerAttributeValue('authorization', 'abc'), 'abc');
    });

    test('ignoreHeaders are case-insensitive', () {
      final capture = NetworkCapture(headers: true, ignoreHeaders: {'Cookie'});
      expect(capture.headerKey('request', 'COOKIE'), isNull);
      expect(
        capture.headerKey('response', 'Content-Type'),
        'http.response.header.content_type',
      );
    });
  });

  group('web options', () {
    test('capture nothing by default', () {
      final capture = const WebInstrumentationOptions().resolveNetworkCapture(
        NetworkCapture.none,
      );
      expect(capture.headers, isFalse);
      expect(capture.responseBodies, isFalse);
      expect(capture.ignoreHeaders, isEmpty);
    });

    test('each flag is independent', () {
      final headers = const WebInstrumentationOptions(
        captureNetworkHeaders: true,
      ).resolveNetworkCapture(NetworkCapture.none);
      expect(headers.headers, isTrue);
      expect(headers.responseBodies, isFalse);

      final bodies = const WebInstrumentationOptions(
        captureResponseBodies: true,
      ).resolveNetworkCapture(NetworkCapture.none);
      expect(bodies.headers, isFalse);
      expect(bodies.responseBodies, isTrue);
    });

    test('deprecated advanceNetworkCapture turns both on', () {
      final capture = const WebInstrumentationOptions(
        advanceNetworkCapture: true,
      ).resolveNetworkCapture(NetworkCapture.none);
      expect(capture.headers, isTrue);
      expect(capture.responseBodies, isTrue);
    });

    test('explicit flags win over advanceNetworkCapture', () {
      final capture = const WebInstrumentationOptions(
        advanceNetworkCapture: true,
        captureResponseBodies: false,
      ).resolveNetworkCapture(NetworkCapture.none);
      expect(capture.headers, isTrue);
      expect(capture.responseBodies, isFalse);
    });

    test('initialize-level flags apply unless the web options set them', () {
      final defaults = NetworkCapture(
        headers: true,
        responseBodies: true,
        ignoreHeaders: {'Cookie'},
      );
      final inherited = const WebInstrumentationOptions(
        ignoreHeaders: {'X-Secret'},
      ).resolveNetworkCapture(defaults);
      expect(inherited.headers, isTrue);
      expect(inherited.responseBodies, isTrue);
      expect(inherited.ignoreHeaders, {'cookie', 'x-secret'});

      final overridden = const WebInstrumentationOptions(
        captureNetworkHeaders: false,
      ).resolveNetworkCapture(defaults);
      expect(overridden.headers, isFalse);
      expect(overridden.responseBodies, isTrue);
    });
  });
}
