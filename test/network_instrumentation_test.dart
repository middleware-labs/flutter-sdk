// Licensed under the Apache License, Version 2.0

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    as sdk;
import 'package:middleware_dart_opentelemetry/testing.dart';
import 'package:middleware_flutter_opentelemetry/middleware_flutter_opentelemetry.dart';

class _UserAgentOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..userAgent = 'app-overrides';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late InMemorySpanExporter exporter;
  final received = <HttpHeaders>[];

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  Future<void> initialize({
    bool enableAutomaticNetworkInstrumentation = true,
    HttpInstrumentationConfig config = const HttpInstrumentationConfig(),
    bool captureNetworkHeaders = false,
    bool captureResponseBodies = false,
    Set<String> ignoreHeaders = const <String>{},
  }) {
    // reset() shuts the previous exporter down.
    exporter = InMemorySpanExporter();
    return FlutterOTel.initialize(
      endpoint: 'http://localhost:4318',
      serviceName: 'network-test',
      spanProcessor: sdk.SimpleSpanProcessor(exporter),
      enableMetrics: false,
      enableLogs: false,
      enableSessionRecording: false,
      flushTracesInterval: null,
      detectPlatformResources: false,
      enableAutomaticNetworkInstrumentation:
          enableAutomaticNetworkInstrumentation,
      networkInstrumentationConfig: config,
      captureNetworkHeaders: captureNetworkHeaders,
      captureResponseBodies: captureResponseBodies,
      ignoreHeaders: ignoreHeaders,
    );
  }

  // Span export runs after `end()` returns.
  Future<List<sdk.Span>> httpSpans() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return exporter.spans
        .where((s) => s.attributes.getString('event.type') == 'xhr')
        .toList();
  }

  setUp(() async {
    // flutter_test installs overrides that answer every request with 400.
    HttpOverrides.global = null;
    received.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      received.add(request.headers);
      await request.drain<void>();
      final response = request.response;
      if (request.uri.path == '/fail') {
        response.statusCode = 500;
      }
      final contentType = request.uri.queryParameters['type'];
      if (contentType != null) {
        response.headers
          ..set(HttpHeaders.contentTypeHeader, contentType)
          ..set('x-access-token', 'secret-token')
          ..set('x-secret', 'hidden')
          ..add('x-multi', 'a')
          ..add('x-multi', 'b');
      }
      final size = int.tryParse(request.uri.queryParameters['size'] ?? '');
      response.write(size != null ? 'x' * size : 'hello world');
      await response.close();
    });
    await initialize();
  });

  tearDown(() async {
    await FlutterOTel.reset();
    await server.close(force: true);
    HttpOverrides.global = null;
  });

  test(
    'package:http requests are traced without wrapping the client',
    () async {
      final response = await http.get(url('/users?id=1'));
      expect(response.body, 'hello world');

      final spans = await httpSpans();
      expect(spans, hasLength(1));
      final span = spans.single;
      expect(span.name, 'GET 127.0.0.1:${server.port}/users');
      expect(span.kind, sdk.SpanKind.client);
      expect(span.status, sdk.SpanStatusCode.Ok);
      expect(span.attributes.getString('http.request.method'), 'GET');
      expect(
        span.attributes.getString('url.full'),
        url('/users?id=1').toString(),
      );
      expect(span.attributes.getString('url.path'), '/users');
      expect(span.attributes.getString('url.query'), 'id=1');
      expect(span.attributes.getInt('http.response.status_code'), 200);
      expect(span.attributes.getInt('http.response.body.size'), 11);

      // W3C and both B3 encodings, carrying this span.
      final headers = received.single;
      final traceId = span.spanContext.traceId.hexString;
      final spanId = span.spanContext.spanId.hexString;
      expect(headers.value('traceparent'), '00-$traceId-$spanId-01');
      expect(headers.value('b3'), '$traceId-$spanId-1');
      expect(headers.value('x-b3-traceid'), traceId);
      expect(headers.value('x-b3-spanid'), spanId);
    },
  );

  test('dio requests are traced without an interceptor', () async {
    final dio = Dio();
    final response = await dio.post<String>(
      url('/orders').toString(),
      data: 'x',
    );
    expect(response.data, 'hello world');

    final spans = await httpSpans();
    expect(spans, hasLength(1));
    expect(spans.single.name, 'POST 127.0.0.1:${server.port}/orders');
    expect(spans.single.attributes.getInt('http.response.status_code'), 200);
    expect(received.single.value('traceparent'), isNotNull);
  });

  test('dart:io HttpClient requests are traced', () async {
    final client = HttpClient();
    final request = await client.getUrl(url('/raw'));
    final response = await request.close();
    await response.drain<void>();
    client.close();

    final spans = await httpSpans();
    expect(spans.single.name, 'GET 127.0.0.1:${server.port}/raw');
  });

  test('HTTP errors mark the span as failed', () async {
    final response = await http.get(url('/fail'));
    expect(response.statusCode, 500);

    final span = (await httpSpans()).single;
    expect(span.status, sdk.SpanStatusCode.Error);
    expect(span.attributes.getInt('http.response.status_code'), 500);
  });

  test('connection failures end the span with the error', () async {
    final port = server.port;
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    await expectLater(
      http.get(Uri.parse('http://127.0.0.1:$port/down')),
      throwsA(isA<http.ClientException>()),
    );

    final span = (await httpSpans()).single;
    expect(span.status, sdk.SpanStatusCode.Error);
    expect(span.attributes.getString('error.type'), isNotNull);
  });

  test('manually wrapped clients get one span, not two', () async {
    final client = http.Client().instrument();
    await client.get(url('/manual'));
    client.close();

    final dio = Dio()..addOTelInstrumentation();
    await dio.get<String>(url('/manual-dio').toString());

    final spans = await httpSpans();
    expect(spans.map((s) => s.name), [
      'GET 127.0.0.1:${server.port}/manual',
      'GET 127.0.0.1:${server.port}/manual-dio',
    ]);
    // The wrappers' own trace headers reach the server.
    for (var i = 0; i < 2; i++) {
      expect(
        received[i].value('traceparent'),
        contains(spans[i].spanContext.spanId.hexString),
      );
    }

    // The next unwrapped request is traced again.
    await http.get(url('/after'));
    expect(await httpSpans(), hasLength(3));
  });

  test('shouldInstrument excludes requests', () async {
    await FlutterOTel.reset();
    await initialize(
      config: HttpInstrumentationConfig(
        shouldInstrument: (url) => url.path != '/health',
      ),
    );

    await http.get(url('/health'));
    expect(await httpSpans(), isEmpty);
    expect(received.single.value('traceparent'), isNull);
  });

  test('the SDK\'s own OTLP exports are never traced', () async {
    await http.post(url('/v1/traces'), body: '{}');
    expect(await httpSpans(), isEmpty);
  });

  test('can be turned off', () async {
    await FlutterOTel.reset();
    expect(HttpOverrides.current, isNull);
    await initialize(enableAutomaticNetworkInstrumentation: false);

    await http.get(url('/off'));
    expect(await httpSpans(), isEmpty);
    expect(received.single.value('traceparent'), isNull);
    expect(NetworkInstrumentation.isActive, isFalse);
  });

  test('chains HttpOverrides the app installed first', () async {
    await FlutterOTel.reset();
    HttpOverrides.global = _UserAgentOverrides();
    await initialize();

    await http.get(url('/chained'));
    expect(received.single.value('user-agent'), 'app-overrides');
    expect(await httpSpans(), hasLength(1));

    await FlutterOTel.reset();
    expect(HttpOverrides.current, isA<_UserAgentOverrides>());
  });

  test('requests run inside an active span are its children', () async {
    final parent = FlutterOTel.tracer.startSpan('parent');
    await sdk.Context.current
        .withSpan(parent)
        .run(() => http.get(url('/child')));
    parent.end();

    final span = (await httpSpans()).single;
    expect(span.spanContext.traceId, parent.spanContext.traceId);
    expect(span.parentSpanContext?.spanId, parent.spanContext.spanId);
  });

  group('header and body capture', () {
    // Header attributes, plus the body attributes (not their sizes).
    bool isCaptureKey(String key) =>
        key.startsWith('http.request.header.') ||
        key.startsWith('http.response.header.') ||
        key == 'http.request.body' ||
        key == 'http.response.body';

    Map<String, Object> captured(sdk.Span span) => <String, Object>{
      for (final a in span.attributes.toList())
        if (isCaptureKey(a.key)) a.key: a.value,
    };

    Future<sdk.Span> post(
      String type, {
      Map<String, String> headers = const {},
    }) async {
      final response = await http.post(
        url('/data?type=${Uri.encodeQueryComponent(type)}'),
        headers: {'X-Custom': 'v1', 'X-Secret': 'nope', ...headers},
        body: '{"password":"hunter2"}',
      );
      expect(response.body, 'hello world');
      return (await httpSpans()).single;
    }

    Future<void> reinitialize({
      HttpInstrumentationConfig config = const HttpInstrumentationConfig(),
      bool captureNetworkHeaders = false,
      bool captureResponseBodies = false,
      Set<String> ignoreHeaders = const <String>{},
    }) async {
      await FlutterOTel.reset();
      await initialize(
        config: config,
        captureNetworkHeaders: captureNetworkHeaders,
        captureResponseBodies: captureResponseBodies,
        ignoreHeaders: ignoreHeaders,
      );
    }

    test('nothing is captured by default', () async {
      final span = await post('application/json');
      expect(captured(span), isEmpty);
      // Sizes and status are still recorded.
      expect(span.attributes.getInt('http.response.status_code'), 200);
      expect(span.attributes.getInt('http.response.body.size'), 11);
      expect(span.attributes.getInt('http.request.body.size'), 22);
    });

    test(
      'captureNetworkHeaders records every header but ignored ones',
      () async {
        await reinitialize(
          captureNetworkHeaders: true,
          ignoreHeaders: {'X-SECRET'},
        );
        final span = await post('application/json; charset=utf-8');
        final attrs = captured(span);

        expect(attrs['http.request.header.x_custom'], 'v1');
        expect(attrs['http.request.header.content_type'], isNotNull);
        expect(attrs['http.request.header.user_agent'], isNotNull);
        expect(
          attrs['http.response.header.content_type'],
          'application/json; charset=utf-8',
        );
        expect(attrs['http.response.header.x_multi'], 'a, b');
        expect(attrs['http.response.header.x_access_token'], '********');
        // ignoreHeaders, both directions.
        expect(attrs.keys.where((k) => k.endsWith('x_secret')), isEmpty);
        // The SDK's own trace headers aren't recorded as the app's.
        expect(attrs.containsKey('http.request.header.traceparent'), isFalse);
        expect(attrs.containsKey('http.request.header.b3'), isFalse);
        // No bodies.
        expect(attrs.containsKey('http.response.body'), isFalse);
        expect(attrs.containsKey('http.request.body'), isFalse);
      },
    );

    test('captureResponseBodies records the body, not headers', () async {
      await reinitialize(captureResponseBodies: true);
      final span = await post('application/json');
      expect(captured(span), {'http.response.body': 'hello world'});
    });

    test('only JSON and plain-text bodies are captured', () async {
      await reinitialize(captureResponseBodies: true);
      const types = {
        'application/json': true,
        'application/problem+json; charset=utf-8': true,
        'text/plain; charset=utf-8': true,
        'TEXT/PLAIN': true,
        'text/html': false,
        'application/octet-stream': false,
      };
      for (final entry in types.entries) {
        final response = await http.get(
          url('/body?type=${Uri.encodeQueryComponent(entry.key)}'),
        );
        expect(response.body, 'hello world');
      }
      final spans = await httpSpans();
      expect(spans, hasLength(types.length));
      final values = types.entries.toList();
      for (var i = 0; i < values.length; i++) {
        expect(
          spans[i].attributes.getString('http.response.body'),
          values[i].value ? 'hello world' : isNull,
          reason: values[i].key,
        );
      }
    });

    test(
      'dio responses are captured without changing what dio reads',
      () async {
        await reinitialize(captureResponseBodies: true);
        final response = await Dio().get<String>(
          url('/dio?type=application/json').toString(),
        );
        expect(response.data, 'hello world');
        final span = (await httpSpans()).single;
        expect(span.attributes.getString('http.response.body'), 'hello world');
      },
    );

    test(
      'bodies are capped at 64 KiB; the app still reads all of it',
      () async {
        await reinitialize(captureResponseBodies: true);
        const size = 100 * 1024;
        final response = await http.get(url('/big?type=text/plain&size=$size'));
        expect(response.bodyBytes, hasLength(size));
        final span = (await httpSpans()).single;
        expect(
          span.attributes.getString('http.response.body'),
          hasLength(64 * 1024),
        );
        expect(span.attributes.getInt('http.response.body.size'), size);
      },
    );

    test('request bodies are never captured', () async {
      await reinitialize(
        captureNetworkHeaders: true,
        captureResponseBodies: true,
      );
      final span = await post('application/json');
      expect(span.attributes.getString('http.request.body'), isNull);
      expect(
        captured(
          span,
        ).values.whereType<String>().where((v) => v.contains('hunter2')),
        isEmpty,
      );
      expect(span.attributes.getString('http.response.body'), 'hello world');
    });

    test(
      'legacy captureRequestHeaders keeps the capturedHeaders allowlist',
      () async {
        await reinitialize(
          config: const HttpInstrumentationConfig(captureRequestHeaders: true),
        );
        final attrs = captured(await post('application/json'));
        expect(attrs.keys.toSet(), {
          'http.request.header.content_type',
          'http.request.header.user_agent',
          'http.request.header.content_length',
        });
      },
    );

    test(
      'a custom capturedHeaders allowlist limits captureNetworkHeaders',
      () async {
        await reinitialize(
          config: const HttpInstrumentationConfig(
            capturedHeaders: {'X-Custom', 'x-access-token'},
          ),
          captureNetworkHeaders: true,
        );
        final attrs = captured(await post('application/json'));
        expect(attrs, {
          'http.request.header.x_custom': 'v1',
          'http.response.header.x_access_token': '********',
        });
      },
    );
  });
}
