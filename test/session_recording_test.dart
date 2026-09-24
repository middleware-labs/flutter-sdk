// Licensed under the Apache License, Version 2.0

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:middleware_flutter_opentelemetry/src/recording/rrweb_events.dart';
import 'package:middleware_flutter_opentelemetry/src/recording/rrweb_exporter.dart';
import 'package:middleware_flutter_opentelemetry/src/recording/session_recording.dart';

/// Decodes a captured /v1/metrics request into its resource attributes and
/// rrweb events.
({Map<String, String> resource, List<Map<String, Object?>> events}) _decode(
  http.Request request,
) {
  final body =
      request.headers['Content-Encoding'] == 'gzip'
          ? utf8.decode(gzip.decode(request.bodyBytes))
          : request.body;
  final resourceMetrics =
      (jsonDecode(body)['resourceMetrics'] as List).single
          as Map<String, dynamic>;
  final resource = {
    for (final a in resourceMetrics['resource']['attributes'] as List)
      a['key'] as String: a['value']['stringValue'] as String,
  };
  final metrics =
      (resourceMetrics['scopeMetrics'] as List).single['metrics'] as List;
  final events = [
    for (final m in metrics)
      () {
        expect(m['name'], 'rum_event');
        final point = (m['gauge']['dataPoints'] as List).single;
        final attrs = {
          for (final a in point['attributes'] as List)
            a['key'] as String: a['value']['stringValue'] as String,
        };
        return <String, Object?>{
          'type': int.parse(attrs['type']!),
          'timestamp': int.parse(attrs['timestamp']!),
          'data': jsonDecode(attrs['data']!),
        };
      }(),
  ];
  return (resource: resource, events: events);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;
  late int status;

  RRWebExporter newExporter() => RRWebExporter(
    target: 'https://acc.middleware.io',
    token: 'rum-token',
    resourceAttributes:
        (sessionId) => {'service.name': 'svc', 'session.id': sessionId},
    client: MockClient((request) async {
      requests.add(request);
      return http.Response('{}', status);
    }),
  );

  setUp(() {
    requests = [];
    status = 200;
  });

  group('RRWebExporter', () {
    test('posts rum_event gauges to /v1/metrics', () async {
      final exporter = newExporter();
      exporter.enqueue(RRWebEvents.meta('https://app/', 400, 800, 1000), 's1');
      exporter.enqueue(RRWebEvents.frameMutation('data:x', 1001), 's1');
      await exporter.flush();
      await exporter.shutdown();

      final request = requests.single;
      expect(request.url.toString(), 'https://acc.middleware.io/v1/metrics');
      expect(request.headers['Authorization'], 'rum-token');
      expect(request.headers['Content-Type'], startsWith('application/json'));
      expect(request.headers['Content-Encoding'], 'gzip');

      final decoded = _decode(request);
      expect(decoded.resource['session.id'], 's1');
      expect(decoded.events.map((e) => e['type']), [4, 3]);
      expect(decoded.events.first['timestamp'], 1000);
      expect(decoded.events.first['data'], {
        'href': 'https://app/',
        'width': 400,
        'height': 800,
      });
    });

    test('sends one payload per session id', () async {
      final exporter = newExporter();
      exporter.enqueue(RRWebEvents.frameMutation('a', 1), 'old');
      exporter.enqueue(RRWebEvents.frameMutation('b', 2), 'new');
      await exporter.flush();
      await exporter.shutdown();

      expect(requests.map((r) => _decode(r).resource['session.id']), [
        'old',
        'new',
      ]);
    });

    test('requeues a failed batch and sends it on the next flush', () async {
      final exporter = newExporter();
      status = 503;
      exporter.enqueue(RRWebEvents.frameMutation('a', 1), 's1');
      await exporter.flush();
      status = 200;
      await exporter.flush();
      await exporter.shutdown();

      expect(requests, hasLength(2));
      expect(_decode(requests.last).events.single['timestamp'], 1);
    });
  });

  group('MiddlewareScreenshotManager', () {
    test(
      'emits Meta + FullSnapshot, then mutations for changed frames only',
      () async {
        final manager = MiddlewareScreenshotManager(
          builder: MiddlewareBuilder(
            target: 'https://acc.middleware.io',
            rumAccessToken: 'rum-token',
          ),
          sessionId: 's1',
          repaintBoundaryKey: GlobalKey(),
        );
        final exporter = newExporter();
        manager.exporterForTest = exporter;

        final frameA = Uint8List.fromList([1, 2, 3]);
        final frameB = Uint8List.fromList([4, 5, 6]);
        manager.setScreenName('home');
        manager.emitFrame(frameA, 400, 800);
        manager.emitFrame(frameA, 400, 800); // unchanged: dropped
        manager.emitFrame(frameB, 400, 800);
        manager.emitFrame(frameB, 800, 400); // resized: new epoch
        manager.updateSessionId('s2');
        manager.emitFrame(frameB, 800, 400); // rotated: new epoch
        await exporter.flush();
        await exporter.shutdown();

        final s1 = _decode(requests[0]).events;
        expect(s1.map((e) => e['type']), [4, 2, 5, 3, 4, 2]);
        final snapshot = s1[1]['data'] as Map;
        final img =
            (((snapshot['node'] as Map)['childNodes'] as List)[1]['childNodes']
                    as List)[1]['childNodes'][0]
                as Map;
        expect(img['attributes']['id'], 'mw-screen');
        expect(
          img['attributes']['src'],
          'data:image/jpeg;base64,${base64Encode(frameA)}',
        );
        expect(s1[2]['data'], {
          'tag': 'screen',
          'payload': {'name': 'home'},
        });

        final s2 = _decode(requests[1]);
        expect(s2.resource['session.id'], 's2');
        expect(s2.events.map((e) => e['type']), [4, 2, 5]);
      },
    );
  });
}
