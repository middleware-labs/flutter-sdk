// Licensed under the Apache License, Version 2.0

// Flutter web fetch/XHR header and response-body capture. Run with
// `flutter test --platform chrome test/web`.

@TestOn('browser')
library;

// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    as sdk;
import 'package:middleware_dart_opentelemetry/testing.dart';
import 'package:middleware_flutter_opentelemetry/middleware_flutter_opentelemetry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySpanExporter exporter;

  Future<void> initialize(WebInstrumentationOptions web) {
    exporter = InMemorySpanExporter();
    return FlutterOTel.initialize(
      endpoint: 'http://localhost:4318',
      serviceName: 'web-network-test',
      spanProcessor: sdk.SimpleSpanProcessor(exporter),
      enableMetrics: false,
      enableLogs: false,
      enableSessionRecording: false,
      flushTracesInterval: null,
      detectPlatformResources: false,
      autoCaptureErrors: false,
      enableAutomaticUserInteractions: false,
      webInstrumentation: WebInstrumentationOptions(
        // Headless Chrome is a bot as far as the SDK is concerned.
        blockBotTraffic: false,
        documentLoad: false,
        webVitals: false,
        longTask: false,
        pageTracking: false,
        errors: false,
        console: false,
        websocket: false,
        captureNetworkHeaders: web.captureNetworkHeaders,
        captureResponseBodies: web.captureResponseBodies,
        advanceNetworkCapture: web.advanceNetworkCapture,
        ignoreHeaders: web.ignoreHeaders,
      ),
    );
  }

  tearDown(FlutterOTel.reset);

  /// A data: URL serving [body] as [type] (fetch and XHR both accept POST).
  String dataUrl(String body, String type) =>
      'data:$type,${Uri.encodeComponent(body)}';

  Future<String> fetch(String url) async {
    final headers =
        JSObject()
          ..setProperty('X-Custom'.toJS, 'v1'.toJS)
          ..setProperty('X-Access-Token'.toJS, 'secret'.toJS)
          ..setProperty('X-Secret'.toJS, 'nope'.toJS);
    final init =
        JSObject()
          ..setProperty('method'.toJS, 'POST'.toJS)
          ..setProperty('headers'.toJS, headers)
          ..setProperty('body'.toJS, '{"password":"hunter2"}'.toJS);
    final fetchFn = globalContext['fetch'] as JSFunction;
    final response =
        await (fetchFn.callAsFunction(null, url.toJS, init)
                as JSPromise<JSObject>)
            .toDart;
    return (await response.callMethod<JSPromise<JSString>>('text'.toJS).toDart)
        .toDart;
  }

  Future<String> xhr(String url) {
    final done = Completer<String>();
    final request =
        (globalContext['XMLHttpRequest'] as JSFunction)
            .callAsConstructor<JSObject>();
    request.callMethod<JSAny?>('open'.toJS, 'GET'.toJS, url.toJS);
    request.callMethod<JSAny?>(
      'setRequestHeader'.toJS,
      'X-Custom'.toJS,
      'v1'.toJS,
    );
    request.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'loadend'.toJS,
      ((JSAny? _) {
        done.complete(
          (request.getProperty<JSString>('responseText'.toJS)).toDart,
        );
      }).toJS,
    );
    request.callMethod<JSAny?>('send'.toJS);
    return done.future;
  }

  // Spans end once the resource-timing wait (300ms) is over.
  Future<sdk.Span> networkSpan(String type) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return exporter.spans.lastWhere(
      (s) => s.attributes.getString('event.type') == type,
    );
  }

  Map<String, Object> captured(sdk.Span span) => <String, Object>{
    for (final a in span.attributes.toList())
      if (a.key.startsWith('http.request.header.') ||
          a.key.startsWith('http.response.header.') ||
          a.key == 'http.request.body' ||
          a.key == 'http.response.body')
        a.key: a.value,
  };

  test('defaults capture nothing', () async {
    await initialize(const WebInstrumentationOptions());
    expect(
      await fetch(dataUrl('{"ok":true}', 'application/json')),
      '{"ok":true}',
    );
    expect(captured(await networkSpan('fetch')), isEmpty);
  });

  test('captureNetworkHeaders only', () async {
    await initialize(
      const WebInstrumentationOptions(
        captureNetworkHeaders: true,
        ignoreHeaders: {'x-SECRET'},
      ),
    );
    await fetch(dataUrl('{"ok":true}', 'application/json'));
    final attrs = captured(await networkSpan('fetch'));
    expect(attrs['http.request.header.x_custom'], 'v1');
    expect(attrs['http.request.header.x_access_token'], '********');
    expect(attrs.containsKey('http.request.header.x_secret'), isFalse);
    expect(attrs['http.response.header.content_type'], 'application/json');
    expect(attrs.containsKey('http.response.body'), isFalse);
    expect(attrs.containsKey('http.request.body'), isFalse);
  });

  test('captureResponseBodies only, JSON and text/plain', () async {
    await initialize(
      const WebInstrumentationOptions(captureResponseBodies: true),
    );
    await fetch(dataUrl('{"ok":true}', 'application/problem+json'));
    expect(captured(await networkSpan('fetch')), {
      'http.response.body': '{"ok":true}',
    });
    await fetch(dataUrl('plain', 'text/plain;charset=utf-8'));
    expect(captured(await networkSpan('fetch')), {
      'http.response.body': 'plain',
    });
    await fetch(dataUrl('<p>x</p>', 'text/html'));
    expect(captured(await networkSpan('fetch')), isEmpty);
  });

  test('XHR: headers and bodies follow the flags', () async {
    await initialize(
      const WebInstrumentationOptions(captureResponseBodies: true),
    );
    expect(await xhr(dataUrl('{"a":1}', 'application/json')), '{"a":1}');
    expect(captured(await networkSpan('xhr')), {
      'http.response.body': '{"a":1}',
    });
    await xhr(dataUrl('<p>x</p>', 'text/html'));
    expect(captured(await networkSpan('xhr')), isEmpty);
    await FlutterOTel.reset();

    await initialize(
      const WebInstrumentationOptions(captureNetworkHeaders: true),
    );
    await xhr(dataUrl('{"a":1}', 'application/json'));
    final attrs = captured(await networkSpan('xhr'));
    expect(attrs['http.request.header.x_custom'], 'v1');
    expect(attrs['http.response.header.content_type'], 'application/json');
    expect(attrs.containsKey('http.response.body'), isFalse);
  });

  test(
    'deprecated advanceNetworkCapture turns both on, never request bodies',
    () async {
      await initialize(
        const WebInstrumentationOptions(advanceNetworkCapture: true),
      );
      await fetch(dataUrl('{"ok":true}', 'application/json'));
      final attrs = captured(await networkSpan('fetch'));
      expect(attrs['http.request.header.x_custom'], 'v1');
      expect(attrs['http.response.body'], '{"ok":true}');
      expect(attrs.containsKey('http.request.body'), isFalse);
    },
  );
}
