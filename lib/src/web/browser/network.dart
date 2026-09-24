// Licensed under the Apache License, Version 2.0

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    as sdk;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

import '../../flutterrific_otel.dart';
import '../web_instrumentation_options.dart';
import '../web_telemetry.dart';
import '../web_utils.dart';
import 'js_helpers.dart';

/// How long to wait for a request's PerformanceResourceTiming entry, which the
/// browser queues after the response settles (upstream OTel uses 300ms).
const _resourceTimingWait = Duration(milliseconds: 300);

const _capturableContentTypes = {
  'application/json',
  'text/plain',
  'text/x-component',
};

final RegExp _serverTimingTraceparent = RegExp(
  '''traceparent;desc=['"]00-([0-9a-f]{32})-([0-9a-f]{16})-01['"]''',
);

/// `fetch` and `XMLHttpRequest` spans, patched at the browser level so that
/// `package:http`, `dio`, Flutter's asset loader and any JS library are all
/// covered. Mirrors the browser SDK's fetch/XHR instrumentations: span name
/// `{METHOD} {host}{path}`, `event.type` fetch|xhr, `resource.*` timings,
/// click attribution and (opt-in) header/body capture.
class NetworkInstrumentation {
  NetworkInstrumentation({required this.options, required this.ignoreUrls})
    : _ignoreHeaders = options.ignoreHeaders.map((h) => h.toLowerCase()).toSet();

  final WebInstrumentationOptions options;
  final List<Pattern> ignoreUrls;
  final Set<String> _ignoreHeaders;

  JSFunction? _origFetch;
  final List<Disposer> _restoreXhr = [];

  void enable() {
    _patchFetch();
    _patchXhr();
  }

  void disable() {
    if (_origFetch != null) {
      jsWindow.setProperty('fetch'.toJS, _origFetch);
      _origFetch = null;
    }
    for (final restore in _restoreXhr.reversed) {
      restore();
    }
    _restoreXhr.clear();
  }

  // -------------------------------------------------------------------------
  // Shared
  // -------------------------------------------------------------------------

  sdk.Span _startSpan(String method, String url, String kind) {
    final uri = Uri.tryParse(url);
    if (!documentHidden) FlutterOTel.notifyUserSessionActivity();
    return WebTelemetry.startSpan(
      computeHttpSpanName(method, url),
      scope:
          kind == 'fetch'
              ? '@opentelemetry/instrumentation-fetch'
              : '@opentelemetry/instrumentation-xml-http-request',
      kind: SpanKind.client,
      attributes: {
        'http.request.method': method.toUpperCase(),
        'url.full': url,
        'event.type': kind,
        'component': kind,
        'resource.type': kind,
        if (uri != null && uri.host.isNotEmpty) 'server.address': uri.host,
        if (uri != null && uri.hasPort) 'server.port': uri.port,
      },
    );
  }

  Map<String, String> _traceHeaders(sdk.Span span) {
    final ctx = span.spanContext;
    final traceId = ctx.traceId.hexString;
    final spanId = ctx.spanId.hexString;
    final format = options.tracePropagationFormat;
    return {
      if (format != TracePropagationFormat.b3)
        'traceparent': '00-$traceId-$spanId-01',
      if (format != TracePropagationFormat.w3c) ...{
        'b3': '$traceId-$spanId-1',
        'X-B3-TraceId': traceId,
        'X-B3-SpanId': spanId,
        'X-B3-Sampled': '1',
      },
    };
  }

  bool _propagate(String url) => shouldPropagateTraceHeaders(
    url,
    locationOrigin,
    options.tracePropagationTargets,
  );

  void _captureHeader(
    Map<String, Object> out,
    String type,
    String name,
    String value,
  ) {
    final lower = name.toLowerCase();
    if (_ignoreHeaders.contains(lower)) return;
    out['http.$type.header.${lower.replaceAll('-', '_')}'] =
        lower == 'x-access-token' ? '*****' : value;
  }

  void _captureServerTiming(Map<String, Object> out, String? serverTiming) {
    if (serverTiming == null) return;
    for (final part in serverTiming.split(',')) {
      final m = _serverTimingTraceparent.firstMatch(part.trim());
      if (m != null) {
        out['link.traceId'] = m[1]!;
        out['link.spanId'] = m[2]!;
      }
    }
  }

  /// Waits for the request's resource-timing entry, adds its timings and
  /// network events, then ends the span.
  void _finish(
    sdk.Span span, {
    required String url,
    required double startPerf,
    required double endPerf,
    required DateTime endTime,
    required String initiatorType,
  }) {
    Timer(_resourceTimingWait, () {
      var end = endTime;
      // Resolved at the end, by start time: the tap that caused the request
      // is registered only after its handlers (which fired the request) ran.
      WebTelemetry.setAttributes(
        span,
        InteractionContext.attributesAt(span.startTime),
      );
      try {
        final entry = _findResource(url, startPerf, endPerf, initiatorType);
        if (entry != null) {
          final r = resourceTimingOf(entry);
          WebTelemetry.setAttributes(span, resourceTimingAttributes(r));
          final origin = timeOrigin;
          r.networkEvents.forEach((name, value) {
            WebTelemetry.addTimelineEvent(span, name, origin, value);
          });
          if (r.responseEnd > 0) {
            final resourceEnd = perfToDateTime(origin, r.responseEnd);
            if (resourceEnd.isAfter(end)) end = resourceEnd;
          }
        }
      } catch (_) {}
      span.end(endTime: end);
    });
  }

  /// The resource entry for [url] that started closest after [startPerf].
  JSObject? _findResource(
    String url,
    double startPerf,
    double endPerf,
    String initiatorType,
  ) {
    List<JSObject> entries;
    try {
      entries = jsList(
        jsPerformance?.callMethod<JSAny?>('getEntriesByName'.toJS, url.toJS),
      );
    } catch (_) {
      return null;
    }
    JSObject? best;
    var bestDelta = double.infinity;
    for (final e in entries) {
      final type = jsStr(e, 'initiatorType');
      if (type != null && type != initiatorType) continue;
      final start = jsNum0(e, 'startTime');
      // 1ms of slack for clock rounding between Date.now and performance.now.
      if (start + 1 < startPerf) continue;
      if (start > endPerf + 1) continue;
      final delta = start - startPerf;
      if (delta < bestDelta) {
        bestDelta = delta;
        best = e;
      }
    }
    return best;
  }

  // -------------------------------------------------------------------------
  // fetch
  // -------------------------------------------------------------------------

  void _patchFetch() {
    final orig = jsGet(jsWindow, 'fetch');
    if (orig == null || !orig.isA<JSFunction>()) return;
    final original = orig as JSFunction;
    _origFetch = original;

    // Through a Proxy: a toJS closure throws when JS passes fewer arguments
    // than it declares, and `fetch(url)` has no init.
    JSAny? patchedFetch(JSAny? thisArg, JSArray<JSAny?> args) {
      final list = jsArgs(args);
      final input = list.isEmpty ? null : list[0];
      JSAny? init = list.length > 1 ? list[1] : null;
      JSAny? callOriginal() => reflectApply(original, thisArg, [
        input,
        if (init != null || list.length > 1) init,
        ...list.skip(2),
      ].toJS);
      String url;
      var method = 'GET';
      final isRequest = jsInstanceOf(input, 'Request');
      try {
        if (isRequest) {
          url = jsStr(input as JSObject, 'url') ?? '';
          method = jsStr(input, 'method') ?? method;
        } else {
          url = resolveUrl(jsToString(input), locationHref);
        }
        if (init != null && init.isA<JSObject>()) {
          method = jsStr(init as JSObject, 'method') ?? method;
        }
      } catch (_) {
        return reflectApply(original, thisArg, args);
      }
      if (url.isEmpty || isUrlIgnored(url, ignoreUrls)) {
        return reflectApply(original, thisArg, args);
      }

      final startPerf = perfNow();
      final span = _startSpan(method, url, 'fetch');
      final captured = <String, Object>{};
      try {
        init = _prepareFetchInit(span, url, input, init, isRequest, captured);
      } catch (_) {
        // never let header injection break the request
      }

      final JSAny? result;
      try {
        result = callOriginal();
      } catch (e) {
        span.setStatus(SpanStatusCode.Error, e.toString());
        span.end();
        rethrow;
      }
      if (result == null || !result.isA<JSPromise>()) {
        span.end();
        return result;
      }

      (result as JSPromise<JSAny?>).toDart.then(
        (response) =>
            _onFetchResponse(span, url, startPerf, response, captured),
        onError: (Object error) {
          WebTelemetry.setAttributes(span, {
            ...captured,
            'error.type': _errorName(error),
          });
          span.setStatus(SpanStatusCode.Error, _errorMessage(error));
          _finish(
            span,
            url: url,
            startPerf: startPerf,
            endPerf: perfNow(),
            endTime: DateTime.now(),
            initiatorType: 'fetch',
          );
        },
      );
      return result;
    }

    jsWindow.setProperty(
      'fetch'.toJS,
      proxyApply(original, (_, thisArg, args) => patchedFetch(thisArg, args)),
    );
  }

  /// Returns the init to call the original fetch with, with trace headers
  /// injected (never mutating the caller's objects) and request details
  /// captured into [captured] when advanced capture is on.
  JSAny? _prepareFetchInit(
    sdk.Span span,
    String url,
    JSAny? input,
    JSAny? init,
    bool isRequest,
    Map<String, Object> captured,
  ) {
    final hasInit = init != null && init.isA<JSObject>();
    final initObj = hasInit ? init as JSObject : null;

    if (options.advanceNetworkCapture) {
      final headersSource =
          jsGet(initObj, 'headers') ??
          (isRequest ? jsGet(input as JSObject, 'headers') : null);
      _forEachHeader(headersSource, (name, value) {
        _captureHeader(captured, 'request', name, value);
      });
      final body = jsGet(initObj, 'body');
      if (body != null) {
        captured['http.request.body'] =
            jsInstanceOf(body, 'ReadableStream')
                ? '[ReadableStream]'
                : limitLen(jsToString(body), messageLimit * 8);
      }
    }

    if (!_propagate(url)) return init;
    final traceHeaders = _traceHeaders(span);

    if (!hasInit && isRequest) {
      final headers = jsObj(input as JSObject, 'headers');
      for (final e in traceHeaders.entries) {
        headers?.callMethod<JSAny?>('set'.toJS, e.key.toJS, e.value.toJS);
      }
      return init;
    }

    final newInit = JSObject();
    if (initObj != null) {
      (globalContext['Object'] as JSObject).callMethod<JSAny?>(
        'assign'.toJS,
        newInit,
        initObj,
      );
    }
    final headersCtor = globalContext['Headers'] as JSFunction;
    final existing =
        jsGet(initObj, 'headers') ??
        (isRequest ? jsGet(input as JSObject, 'headers') : null);
    final headers =
        existing == null
            ? headersCtor.callAsConstructor<JSObject>()
            : headersCtor.callAsConstructor<JSObject>(existing);
    for (final e in traceHeaders.entries) {
      headers.callMethod<JSAny?>('set'.toJS, e.key.toJS, e.value.toJS);
    }
    newInit.setProperty('headers'.toJS, headers);
    return newInit;
  }

  void _onFetchResponse(
    sdk.Span span,
    String url,
    double startPerf,
    JSAny? response,
    Map<String, Object> captured,
  ) {
    final endPerf = perfNow();
    final endTime = DateTime.now();
    final attrs = <String, Object>{...captured};
    var bodyPending = false;
    if (response != null && response.isA<JSObject>()) {
      final res = response as JSObject;
      final status = jsNum(res, 'status')?.toInt() ?? 0;
      attrs['http.response.status_code'] = status;
      final headers = jsObj(res, 'headers');
      final contentLength = _getHeader(headers, 'content-length');
      if (contentLength != null && int.tryParse(contentLength) != null) {
        attrs['http.response.body.size'] = int.parse(contentLength);
      }
      if (status >= 400) {
        attrs['error.type'] = '$status';
        span.setStatus(SpanStatusCode.Error);
      }
      if (options.advanceNetworkCapture) {
        _forEachHeader(headers, (name, value) {
          _captureHeader(attrs, 'response', name, value);
        });
        _captureServerTiming(attrs, _getHeader(headers, 'server-timing'));
        final contentType = (_getHeader(headers, 'content-type') ?? '')
            .split(';')
            .first
            .trim()
            .toLowerCase();
        if (_capturableContentTypes.contains(contentType)) {
          bodyPending = true;
          _readFetchBody(res).then((text) {
            if (text != null && text.trim().isNotEmpty) {
              attrs['http.response.body'] = limitLen(
                text.trim(),
                messageLimit * 8,
              );
            }
          }).whenComplete(() {
            WebTelemetry.setAttributes(span, attrs);
            _finish(
              span,
              url: url,
              startPerf: startPerf,
              endPerf: endPerf,
              endTime: endTime,
              initiatorType: 'fetch',
            );
          });
        }
      }
    }
    if (bodyPending) return;
    WebTelemetry.setAttributes(span, attrs);
    _finish(
      span,
      url: url,
      startPerf: startPerf,
      endPerf: endPerf,
      endTime: endTime,
      initiatorType: 'fetch',
    );
  }

  Future<String?> _readFetchBody(JSObject response) async {
    try {
      final clone = response.callMethod<JSObject>('clone'.toJS);
      final text =
          await clone.callMethod<JSPromise<JSString>>('text'.toJS).toDart;
      return text.toDart;
    } catch (_) {
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // XMLHttpRequest
  // -------------------------------------------------------------------------

  void _patchXhr() {
    final ctor = jsGet(jsWindow, 'XMLHttpRequest');
    if (ctor == null || !ctor.isA<JSObject>()) return;
    final proto = jsObj(ctor as JSObject, 'prototype');
    if (proto == null) return;

    _restoreXhr.add(
      patchMethod(proto, 'open', (original, thisArg, args) {
        try {
          final list = jsArgs(args);
          final state = _XhrState(
            method: list.isNotEmpty ? jsToString(list[0]) : 'GET',
            url: resolveUrl(
              list.length > 1 ? jsToString(list[1]) : '',
              locationHref,
            ),
          );
          (thisArg as JSObject).setProperty('__mwOtel'.toJS, state.toJSBox);
        } catch (_) {}
        return reflectApply(original, thisArg, args);
      }),
    );

    // Trace headers go through the unpatched setter so advanced capture
    // doesn't record the SDK's own headers.
    final origSetHeader = jsGet(proto, 'setRequestHeader');
    _restoreXhr.add(
      patchMethod(proto, 'setRequestHeader', (original, thisArg, args) {
        if (options.advanceNetworkCapture) {
          final state = _stateOf(thisArg);
          final list = jsArgs(args);
          if (state != null && list.length >= 2) {
            _captureHeader(
              state.captured,
              'request',
              jsToString(list[0]),
              jsToString(list[1]),
            );
          }
        }
        return reflectApply(original, thisArg, args);
      }),
    );

    _restoreXhr.add(
      patchMethod(proto, 'send', (original, thisArg, args) {
        final state = _stateOf(thisArg);
        if (state != null &&
            state.span == null &&
            !isUrlIgnored(state.url, ignoreUrls)) {
          try {
            final list = jsArgs(args);
            _startXhr(
              thisArg as JSObject,
              state,
              list.isEmpty ? null : list[0],
              origSetHeader as JSFunction,
            );
          } catch (_) {}
        }
        return reflectApply(original, thisArg, args);
      }),
    );
  }

  _XhrState? _stateOf(JSAny? xhr) {
    if (xhr == null || !xhr.isA<JSObject>()) return null;
    try {
      final boxed = jsGet(xhr as JSObject, '__mwOtel');
      if (boxed == null) return null;
      final state = (boxed as JSBoxedDartObject).toDart;
      return state is _XhrState ? state : null;
    } catch (_) {
      return null;
    }
  }

  void _startXhr(
    JSObject xhr,
    _XhrState state,
    JSAny? body,
    JSFunction origSetHeader,
  ) {
    final span = state.span = _startSpan(state.method, state.url, 'xhr');
    final startPerf = perfNow();
    if (_propagate(state.url)) {
      for (final e in _traceHeaders(span).entries) {
        try {
          origSetHeader.callAsFunction(xhr, e.key.toJS, e.value.toJS);
        } catch (_) {}
      }
    }
    if (options.advanceNetworkCapture && body != null) {
      state.captured['http.request.body'] = limitLen(
        jsToString(body),
        messageLimit * 8,
      );
    }

    String? failure;
    void onFailure(String kind) => failure = kind;
    _once(xhr, 'error', () => onFailure('error'));
    _once(xhr, 'abort', () => onFailure('abort'));
    _once(xhr, 'timeout', () => onFailure('timeout'));
    _once(xhr, 'loadend', () {
      final endPerf = perfNow();
      final endTime = DateTime.now();
      final attrs = <String, Object>{...state.captured};
      final status = jsNum(xhr, 'status')?.toInt() ?? 0;
      attrs['http.response.status_code'] = status;
      if (failure != null) {
        attrs['error.type'] = failure!;
        span.setStatus(SpanStatusCode.Error, failure);
      } else if (status >= 400) {
        attrs['error.type'] = '$status';
        span.setStatus(SpanStatusCode.Error);
      }
      if (options.advanceNetworkCapture) {
        _captureXhrResponse(xhr, attrs);
      }
      WebTelemetry.setAttributes(span, attrs);
      _finish(
        span,
        url: state.url,
        startPerf: startPerf,
        endPerf: endPerf,
        endTime: endTime,
        initiatorType: 'xmlhttprequest',
      );
    });
  }

  void _captureXhrResponse(JSObject xhr, Map<String, Object> attrs) {
    try {
      final raw =
          xhr.callMethod<JSString>('getAllResponseHeaders'.toJS).toDart;
      for (final line in raw.split(RegExp(r'[\r\n]+'))) {
        final idx = line.indexOf(': ');
        if (idx <= 0) continue;
        _captureHeader(
          attrs,
          'response',
          line.substring(0, idx),
          line.substring(idx + 2),
        );
        if (line.substring(0, idx).toLowerCase() == 'server-timing') {
          _captureServerTiming(attrs, line.substring(idx + 2));
        }
      }
    } catch (_) {}
    try {
      final type = jsStr(xhr, 'responseType') ?? '';
      if (type == '' || type == 'text') {
        final text = jsStr(xhr, 'responseText');
        if (text != null && text.isNotEmpty) {
          attrs['http.response.body'] = limitLen(text, messageLimit * 8);
        }
      }
    } catch (_) {
      // responseText throws for non-text response types
    }
  }

  void _once(JSObject target, String type, void Function() fn) {
    final options = JSObject()..setProperty('once'.toJS, true.toJS);
    target.callMethod<JSAny?>(
      'addEventListener'.toJS,
      type.toJS,
      ((JSAny? _) {
        try {
          fn();
        } catch (_) {}
      }).toJS,
      options,
    );
  }

  // -------------------------------------------------------------------------
  // Headers helpers
  // -------------------------------------------------------------------------

  String? _getHeader(JSObject? headers, String name) {
    if (headers == null) return null;
    try {
      final v = headers.callMethod<JSAny?>('get'.toJS, name.toJS);
      return v != null && v.isA<JSString>() ? (v as JSString).toDart : null;
    } catch (_) {
      return null;
    }
  }

  /// Iterates a Headers instance, a `[[name, value]]` array or a plain object.
  void _forEachHeader(
    JSAny? source,
    void Function(String name, String value) fn,
  ) {
    if (source == null || !source.isA<JSObject>()) return;
    try {
      final headersCtor = globalContext['Headers'] as JSFunction;
      final headers =
          jsInstanceOf(source, 'Headers')
              ? source as JSObject
              : headersCtor.callAsConstructor<JSObject>(source);
      headers.callMethod<JSAny?>(
        'forEach'.toJS,
        ((JSAny? value, JSAny? name) {
          fn(jsToString(name), jsToString(value));
        }).toJS,
      );
    } catch (_) {}
  }

  // A rejected fetch surfaces the JS error object itself (usually a
  // TypeError) as the Dart error.
  String _errorName(Object error) {
    try {
      // ignore: invalid_runtime_check_with_js_interop_types
      return jsStr(error as JSObject, 'name') ?? 'Error';
    } catch (_) {
      return error.runtimeType.toString();
    }
  }

  String _errorMessage(Object error) {
    try {
      // ignore: invalid_runtime_check_with_js_interop_types
      final o = error as JSObject;
      return jsStr(o, 'message') ?? jsToString(o);
    } catch (_) {
      return error.toString();
    }
  }
}

class _XhrState {
  _XhrState({required this.method, required this.url});
  final String method;
  final String url;
  final Map<String, Object> captured = {};
  sdk.Span? span;
}
