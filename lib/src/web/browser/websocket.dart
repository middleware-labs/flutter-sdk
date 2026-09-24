// Licensed under the Apache License, Version 2.0

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    as sdk;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

import '../web_telemetry.dart';
import '../web_utils.dart';
import 'js_helpers.dart';

const _scope = 'middleware-websocket-instrumentation';

/// WebSocket spans, as in the browser SDK: `connect` (open or failure),
/// `send` (PRODUCER, `http.request_content_length`) and `onmessage`
/// (CONSUMER, `http.response_content_length`), all `component=websocket`,
/// `event.type=websocket`. Covers `package:web_socket_channel` on web, which
/// sits on the browser WebSocket.
class WebSocketInstrumentation {
  WebSocketInstrumentation({required this.ignoreUrls});

  final List<Pattern> ignoreUrls;
  JSAny? _original;

  void enable() {
    final ctor = jsGet(jsWindow, 'WebSocket');
    if (ctor == null || !ctor.isA<JSFunction>()) return;
    _original = ctor;
    jsWindow.setProperty(
      'WebSocket'.toJS,
      proxyConstruct(ctor as JSFunction, (target, args, newTarget) {
        final list = jsArgs(args);
        final url = list.isEmpty ? '' : jsToString(list.first);
        if (isUrlIgnored(url, ignoreUrls)) {
          return reflectConstruct(target, args, newTarget);
        }
        return _construct(target, args, newTarget, url, list);
      }),
    );
  }

  void disable() {
    if (_original != null) {
      jsWindow.setProperty('WebSocket'.toJS, _original);
      _original = null;
    }
  }

  JSObject _construct(
    JSFunction target,
    JSArray<JSAny?> args,
    JSAny? newTarget,
    String url,
    List<JSAny?> list,
  ) {
    final protocols = list.length > 1 ? list[1] : null;
    final connect = WebTelemetry.startSpan(
      'connect',
      scope: _scope,
      kind: SpanKind.client,
      attributes: {
        'component': 'websocket',
        'event.type': 'websocket',
        if (url.isNotEmpty) 'http.url': url,
        if (url.isNotEmpty) 'url.full': url,
        if (protocols != null)
          'protocols':
              protocols.isA<JSString>()
                  ? (protocols as JSString).toDart
                  : safeJson((protocols as JSObject).dartify()),
      },
    );
    final JSObject ws;
    try {
      ws = reflectConstruct(target, args, newTarget);
    } catch (e) {
      _endExceptionally(connect, 'Error', e.toString(), null);
      rethrow;
    }

    var connected = false;
    listen(ws, 'open', (_) {
      connected = true;
      connect.end();
    });
    listen(ws, 'error', (event) {
      if (!connected && connect.isRecording) {
        _endExceptionally(
          connect,
          'Error',
          jsStr(event, 'message') ?? 'Websocket could not connect.',
          null,
        );
      } else {
        _span(ws, 'error', SpanKind.client).end();
      }
    });
    _patchSend(ws);
    _patchMessageListeners(ws);
    return ws;
  }

  sdk.Span _span(JSObject ws, String name, SpanKind kind) {
    final url = jsStr(ws, 'url') ?? '';
    return WebTelemetry.startSpan(
      name,
      scope: _scope,
      kind: kind,
      attributes: {
        'component': 'websocket',
        'event.type': 'websocket',
        'http.url': url,
        'url.full': url,
        'protocol': jsStr(ws, 'protocol') ?? '',
      },
    );
  }

  void _patchSend(JSObject ws) {
    patchMethod(ws, 'send', (original, thisArg, args) {
      final span = _span(ws, 'send', SpanKind.producer);
      final list = jsArgs(args);
      final size = list.isEmpty ? null : _size(list.first);
      if (size != null) {
        span.setIntAttribute('http.request_content_length', size);
      }
      try {
        final result = reflectApply(original, thisArg, args);
        span.end();
        return result;
      } catch (e) {
        _endExceptionally(span, 'Error', e.toString(), null);
        rethrow;
      }
    });
  }

  /// Wraps `message` listeners (addEventListener and `onmessage`) so each
  /// delivery is an `onmessage` span.
  void _patchMessageListeners(JSObject ws) {
    // Keyed by the listener's JS identity (a Dart map can't key JS values
    // reliably across compilers).
    final wrapped =
        (globalContext['WeakMap'] as JSFunction).callAsConstructor<JSObject>();
    JSFunction wrap(JSAny callback) {
      return ((JSAny? event) {
        final span = _span(ws, 'onmessage', SpanKind.consumer);
        final size = _size(jsGet(event as JSObject?, 'data'));
        if (size != null) {
          span.setIntAttribute('http.response_content_length', size);
        }
        try {
          if (callback.isA<JSFunction>()) {
            (callback as JSFunction).callAsFunction(ws, event);
          } else {
            (callback as JSObject).callMethod<JSAny?>(
              'handleEvent'.toJS,
              event,
            );
          }
        } finally {
          span.end();
        }
      }).toJS;
    }

    patchMethod(ws, 'addEventListener', (original, thisArg, args) {
      final list = jsArgs(args);
      if (list.length < 2 ||
          jsToString(list[0]) != 'message' ||
          list[1] == null) {
        return reflectApply(original, thisArg, args);
      }
      final callback = list[1]!;
      if (!callback.isA<JSObject>()) {
        return reflectApply(original, thisArg, args);
      }
      var patched = wrapped.callMethod<JSAny?>('get'.toJS, callback);
      if (patched == null) {
        patched = wrap(callback);
        wrapped.callMethod<JSAny?>('set'.toJS, callback, patched);
      }
      return reflectApply(
        original,
        thisArg,
        [list[0], patched, if (list.length > 2) list[2]].toJS,
      );
    });
    patchMethod(ws, 'removeEventListener', (original, thisArg, args) {
      final list = jsArgs(args);
      final patched =
          list.length >= 2 &&
                  jsToString(list[0]) == 'message' &&
                  list[1] != null &&
                  list[1]!.isA<JSObject>()
              ? wrapped.callMethod<JSAny?>('get'.toJS, list[1])
              : null;
      if (patched != null) {
        return reflectApply(
          original,
          thisArg,
          [list[0], patched, if (list.length > 2) list[2]].toJS,
        );
      }
      return reflectApply(original, thisArg, args);
    });
  }

  int? _size(JSAny? data) {
    if (data == null) return null;
    if (data.isA<JSString>()) return (data as JSString).toDart.length;
    if (!data.isA<JSObject>()) return null;
    final o = data as JSObject;
    final n = jsNum(o, 'byteLength') ?? jsNum(o, 'size') ?? jsNum(o, 'length');
    return n?.toInt();
  }

  void _endExceptionally(
    sdk.Span span,
    String name,
    String message,
    String? stack,
  ) {
    WebTelemetry.setAttributes(span, {
      'event.type': 'error',
      'error.message': message,
      'error.object': name,
      if (stack != null) 'error.stack': limitLen(stack, stackLimit),
    });
    span.setStatus(SpanStatusCode.Error, limitLen(message, messageLimit));
    span.end();
  }
}
