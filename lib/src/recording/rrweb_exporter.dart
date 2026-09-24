// Licensed under the Apache License, Version 2.0

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'gzip.dart';
import 'rrweb_events.dart';

/// Buffers rrweb events and ships them through the metrics endpoint using the
/// same wire format as the browser and native SDKs' session recorders: an
/// OTLP-JSON `MetricsData` whose metrics are `rum_event` gauges with datapoint
/// attributes `type` / `timestamp` / `data`, POSTed to `{target}/v1/metrics`.
///
/// Buffering policy (in-memory only):
///  - flush every [_flushInterval], or as soon as the buffer holds
///    [_flushThresholdBytes] of serialized event data;
///  - failed batches are retried up to [_maxRetries] times on later flushes;
///  - when the buffer exceeds [_maxBufferBytes] / [_maxBufferEvents], the
///    oldest incremental events are dropped first — Meta and FullSnapshot
///    events are kept because the frames that follow them are unplayable
///    without them.
class RRWebExporter {
  static const Duration _flushInterval = Duration(seconds: 5);
  static const int _flushThresholdBytes = 512 * 1024;
  static const int _maxBufferBytes = 3 * 1024 * 1024;
  static const int _maxBufferEvents = 300;
  static const int _maxRetries = 3;

  final Uri _endpoint;
  final String _token;
  final Map<String, String> Function(String sessionId) _resourceAttributes;
  final http.Client _client;

  final ListQueue<_PendingEvent> _buffer = ListQueue<_PendingEvent>();
  int _bufferBytes = 0;
  bool _flushInFlight = false;
  bool _shutdown = false;
  Timer? _timer;

  RRWebExporter({
    required String target,
    required String token,
    required Map<String, String> Function(String sessionId) resourceAttributes,
    http.Client? client,
  }) : _endpoint = Uri.parse('$target/v1/metrics'),
       _token = token,
       _resourceAttributes = resourceAttributes,
       _client = client ?? http.Client() {
    _timer = Timer.periodic(_flushInterval, (_) => unawaited(flush()));
  }

  void enqueue(RRWebEvent event, String sessionId) {
    if (_shutdown) return;
    final pending = _PendingEvent(
      sessionId,
      event.type,
      event.timestamp,
      jsonEncode(event.data),
    );
    _buffer.addLast(pending);
    _bufferBytes += pending.dataJson.length;
    _evictIfNeeded();
    if (_bufferBytes >= _flushThresholdBytes) {
      unawaited(flush());
    }
  }

  /// Sends everything currently buffered. Completes when the send settles;
  /// a flush already in flight makes this a no-op.
  Future<void> flush() async {
    if (_flushInFlight || _buffer.isEmpty) return;
    _flushInFlight = true;
    try {
      final batch = _buffer.toList();
      _buffer.clear();
      _bufferBytes = 0;
      // Keep per-session streams intact: one payload per session id.
      final bySession = <String, List<_PendingEvent>>{};
      for (final event in batch) {
        (bySession[event.sessionId] ??= []).add(event);
      }
      for (final entry in bySession.entries) {
        final body = _buildOtlpBody(entry.key, entry.value);
        if (!await _send(body)) {
          _requeue(entry.value);
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Session replay: flush failed: $e');
    } finally {
      _flushInFlight = false;
    }
  }

  /// Flushes what is left and releases the HTTP client.
  Future<void> shutdown() async {
    if (_shutdown) return;
    _timer?.cancel();
    _timer = null;
    // A flush may still be in flight; give it a moment to requeue failures.
    for (var i = 0; _flushInFlight && i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await flush();
    _shutdown = true;
    _client.close();
  }

  void _evictIfNeeded() {
    while (_buffer.length > _maxBufferEvents ||
        _bufferBytes > _maxBufferBytes) {
      final victim = _buffer.firstWhere(
        (e) => !e.isKeyframe,
        orElse: () => _buffer.first,
      );
      _buffer.remove(victim);
      _bufferBytes -= victim.dataJson.length;
      if (kDebugMode) {
        debugPrint(
          'Session replay: buffer full - dropped a type=${victim.type} event',
        );
      }
    }
  }

  void _requeue(List<_PendingEvent> events) {
    final retryable = events.where((e) => e.retries < _maxRetries).toList();
    final dropped = events.length - retryable.length;
    if (dropped > 0 && kDebugMode) {
      debugPrint(
        'Session replay: dropped $dropped events after $_maxRetries failed sends',
      );
    }
    for (final event in retryable.reversed) {
      event.retries++;
      _buffer.addFirst(event);
      _bufferBytes += event.dataJson.length;
    }
    _evictIfNeeded();
  }

  /// Builds the OTLP-JSON payload. Field names are camelCase to match the
  /// browser SDK's RRWebExporter output, which this backend path was built for.
  String _buildOtlpBody(String sessionId, List<_PendingEvent> events) {
    final resourceAttributes =
        _resourceAttributes(
          sessionId,
        ).entries.map((e) => _attr(e.key, e.value)).toList();
    final metrics =
        events
            .map(
              (event) => {
                'name': 'rum_event',
                'gauge': {
                  'dataPoints': [
                    {
                      'attributes': [
                        _attr('type', event.type.toString()),
                        _attr('timestamp', event.timestampMs.toString()),
                        // data is the event payload's JSON, shipped as a string
                        _attr('data', event.dataJson),
                      ],
                      'timeUnixNano': '${event.timestampMs}000000',
                      'asDouble': 0,
                    },
                  ],
                },
              },
            )
            .toList();
    return jsonEncode({
      'resourceMetrics': [
        {
          'resource': {
            'attributes': resourceAttributes,
            'droppedAttributesCount': 0,
          },
          'scopeMetrics': [
            {'scope': <String, Object>{}, 'metrics': metrics},
          ],
        },
      ],
    });
  }

  Map<String, Object> _attr(String key, String value) => {
    'key': key,
    'value': {'stringValue': value},
  };

  Future<bool> _send(String body) async {
    try {
      final raw = Uint8List.fromList(utf8.encode(body));
      final compressed = await gzipBytes(raw);
      final response = await _client.post(
        _endpoint,
        headers: {
          'Authorization': _token,
          'Content-Type': 'application/json',
          if (compressed != null) 'Content-Encoding': 'gzip',
        },
        body: compressed ?? raw,
      );
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      if (!ok && kDebugMode) {
        debugPrint(
          'Session replay: export failed with status ${response.statusCode}',
        );
      }
      return ok;
    } catch (e) {
      if (kDebugMode) debugPrint('Session replay: export failed: $e');
      return false;
    }
  }
}

class _PendingEvent {
  final String sessionId;
  final int type;
  final int timestampMs;
  final String dataJson;
  int retries = 0;

  _PendingEvent(this.sessionId, this.type, this.timestampMs, this.dataJson);

  bool get isKeyframe =>
      type == RRWebEvents.typeFullSnapshot || type == RRWebEvents.typeMeta;
}
