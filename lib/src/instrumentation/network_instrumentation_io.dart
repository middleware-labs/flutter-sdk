// Licensed under the Apache License, Version 2.0

// Automatic HTTP spans on Android, iOS and desktop.
//
// On these platforms every Dart HTTP client (package:http's IOClient, dio's
// IOHttpClientAdapter, NetworkImage, WebSocket.connect, ...) sits on dart:io's
// HttpClient, and `HttpClient()` asks `HttpOverrides.current` for its
// instance. A global HttpOverrides that wraps each client traces every request
// without the app wrapping anything. Clients that don't use HttpClient
// (cupertino_http, cronet_http, gRPC's HTTP/2 transport) aren't covered.
//
// Spans have OTelHttpClient's name, attributes and trace headers, so bifrost
// reads them the same way. A span runs from opening the connection to the
// last byte of the response body.
//
// Nothing here may break a request: every instrumentation step is guarded and
// falls back to the plain client.
//
// Opt-in capture (`captureNetworkHeaders`, `captureResponseBodies`) follows
// the browser SDK: all request/response headers but `ignoreHeaders`, and JSON
// / plain-text response bodies teed off the stream the app reads.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

import '../common/network_capture.dart';
import '../web/web_utils.dart' show defaultIgnoredUrls;

/// Bytes of a response body kept for `http.response.body`.
const int maxCapturedBodyBytes = 64 * 1024;

_OTelHttpOverrides? _overrides;
_ManualHttpSpanTracker? _tracker;

bool get isActive => _overrides?.enabled ?? false;

void enable(HttpInstrumentationConfig config, {NetworkCapture? capture}) {
  capture ??= NetworkCapture.none;
  final installed = _overrides;
  if (installed != null && identical(HttpOverrides.current, installed)) {
    installed.configure(config, capture);
  } else {
    // Something replaced our overrides since the last enable (or this is the
    // first): chain whatever is installed now, e.g. an app's
    // badCertificateCallback overrides.
    installed?.enabled = false;
    final overrides = _OTelHttpOverrides(
      HttpOverrides.current,
      config,
      capture,
    );
    HttpOverrides.global = overrides;
    _overrides = overrides;
  }
}

// Wraps the processor before the TracerProvider is built. Adding a processor
// afterwards races TracerProvider.forceFlush, which iterates the processor
// list across awaits.
SpanProcessor trackManualSpans(SpanProcessor processor) =>
    _tracker = _ManualHttpSpanTracker(processor);

void disable() {
  final installed = _overrides;
  if (installed == null) return;
  // Clients created while enabled keep the wrapper; this makes them pass
  // requests straight through.
  installed.enabled = false;
  if (identical(HttpOverrides.current, installed)) {
    HttpOverrides.global = installed.previous;
  }
  _overrides = null;
  _tracker = null;
}

class _OTelHttpOverrides extends HttpOverrides {
  _OTelHttpOverrides(
    this.previous,
    HttpInstrumentationConfig config,
    NetworkCapture capture,
  ) {
    configure(config, capture);
  }

  final HttpOverrides? previous;
  bool enabled = true;
  late HttpInstrumentationConfig config;
  late _CapturePolicy capture;
  late TextMapPropagator<Map<String, String>, String> propagator;

  void configure(HttpInstrumentationConfig config, NetworkCapture capture) {
    this.config = config;
    this.capture = _CapturePolicy(config, capture);
    propagator = _propagatorFor(config.tracePropagationFormat);
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) => _OTelHttpClient(
    previous?.createHttpClient(context) ?? super.createHttpClient(context),
    this,
  );

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}

/// `HttpInstrumentationConfig`'s header options combined with the SDK's
/// `captureNetworkHeaders` / `captureResponseBodies` / `ignoreHeaders`.
///
/// `captureNetworkHeaders` turns on both directions and records every header
/// (browser parity) unless the app replaced `capturedHeaders`' default
/// allowlist, which then still applies. Without it, the config's own
/// `captureRequestHeaders` / `captureResponseHeaders` keep recording the
/// `capturedHeaders` allowlist as before.
class _CapturePolicy {
  _CapturePolicy(HttpInstrumentationConfig config, this.capture)
    : requestHeaders = capture.headers || config.captureRequestHeaders,
      responseHeaders = capture.headers || config.captureResponseHeaders,
      headerNames =
          capture.headers && _isDefaultAllowlist(config.capturedHeaders)
              ? null
              : config.capturedHeaders.map((h) => h.toLowerCase()).toSet();

  final NetworkCapture capture;
  final bool requestHeaders;
  final bool responseHeaders;

  /// Headers recorded; null records all of them.
  final Set<String>? headerNames;

  bool get responseBodies => capture.responseBodies;

  static const Set<String> _defaultAllowlist = <String>{
    'content-type',
    'content-length',
    'user-agent',
  };

  static bool _isDefaultAllowlist(Set<String> names) =>
      names.length == _defaultAllowlist.length &&
      names.every((n) => _defaultAllowlist.contains(n.toLowerCase()));
}

/// Spans started by the opt-in wrappers (`OTelHttpClient`,
/// `OTelDioInterceptor`) whose request hasn't reached dart:io yet.
///
/// Both start their span before the request opens a connection, so when
/// [claim] finds one with the same name, that request is already traced and
/// goes through untouched: apps that wrapped their clients by hand don't get
/// two spans per request. Every other call goes to [_delegate].
class _ManualHttpSpanTracker implements SpanProcessor {
  _ManualHttpSpanTracker(this._delegate);

  final SpanProcessor _delegate;
  final Map<String, List<Span>> _pending = <String, List<Span>>{};
  bool _startingOwnSpan = false;

  Span startOwnSpan(Span Function() start) {
    _startingOwnSpan = true;
    try {
      return start();
    } finally {
      _startingOwnSpan = false;
    }
  }

  bool claim(String spanName) {
    final spans = _pending[spanName];
    if (spans == null) return false;
    spans.removeAt(0);
    if (spans.isEmpty) _pending.remove(spanName);
    return true;
  }

  @override
  Future<void> onStart(Span span, Context? parentContext) {
    _track(span);
    return _delegate.onStart(span, parentContext);
  }

  void _track(Span span) {
    if (_startingOwnSpan || span.kind != SpanKind.client) return;
    // Processors read span attributes; the exporters do the same.
    // ignore: invalid_use_of_visible_for_testing_member
    if (span.attributes.getString(_eventType) != 'xhr') return;
    (_pending[span.name] ??= <Span>[]).add(span);
  }

  @override
  Future<void> onEnd(Span span) {
    final spans = _pending[span.name];
    if (spans != null) {
      spans.removeWhere((pending) => identical(pending, span));
      if (spans.isEmpty) _pending.remove(span.name);
    }
    return _delegate.onEnd(span);
  }

  @override
  Future<void> onNameUpdate(Span span, String newName) =>
      _delegate.onNameUpdate(span, newName);

  @override
  Future<void> shutdown() {
    _pending.clear();
    return _delegate.shutdown();
  }

  @override
  Future<void> forceFlush() => _delegate.forceFlush();
}

class _OTelHttpClient implements HttpClient {
  _OTelHttpClient(this._inner, this._overrides);

  final HttpClient _inner;
  final _OTelHttpOverrides _overrides;

  Future<HttpClientRequest> _instrument(
    String method,
    Uri url,
    Future<HttpClientRequest> Function() open,
  ) {
    final overrides = _overrides;
    final config = overrides.config;
    final name = _httpSpanName(method, url);
    final tracker = _tracker;
    _RequestSpan? span;
    try {
      if (overrides.enabled &&
          !_isIgnored(url, config) &&
          !(tracker?.claim(name) ?? false)) {
        Span start() => OTel.tracer().startSpan(
          name,
          kind: SpanKind.client,
          attributes: _requestAttributes(method, url, config).toAttributes(),
        );
        span = _RequestSpan(
          tracker == null ? start() : tracker.startOwnSpan(start),
          config,
          overrides.capture,
        );
      }
    } catch (_) {
      span = null;
    }
    if (span == null) return open();

    final Future<HttpClientRequest> opening;
    try {
      opening = open();
    } catch (error, stack) {
      span.end(error: error, stack: stack);
      rethrow;
    }
    return opening.then(
      (request) {
        span!.injectHeaders(request, overrides.propagator);
        return _OTelHttpClientRequest(request, span);
      },
      onError: (Object error, StackTrace stack) {
        span!.end(error: error, stack: stack);
        return Future<HttpClientRequest>.error(error, stack);
      },
    );
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _instrument(
    method,
    _openUri(host, port, path),
    () => _inner.open(method, host, port, path),
  );

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _instrument(method, url, () => _inner.openUrl(method, url));

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _instrument(
        'get',
        _openUri(host, port, path),
        () => _inner.get(host, port, path),
      );

  @override
  Future<HttpClientRequest> getUrl(Uri url) =>
      _instrument('get', url, () => _inner.getUrl(url));

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _instrument(
        'post',
        _openUri(host, port, path),
        () => _inner.post(host, port, path),
      );

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _instrument('post', url, () => _inner.postUrl(url));

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _instrument(
        'put',
        _openUri(host, port, path),
        () => _inner.put(host, port, path),
      );

  @override
  Future<HttpClientRequest> putUrl(Uri url) =>
      _instrument('put', url, () => _inner.putUrl(url));

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _instrument(
        'delete',
        _openUri(host, port, path),
        () => _inner.delete(host, port, path),
      );

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _instrument('delete', url, () => _inner.deleteUrl(url));

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _instrument(
        'patch',
        _openUri(host, port, path),
        () => _inner.patch(host, port, path),
      );

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _instrument('patch', url, () => _inner.patchUrl(url));

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _instrument(
        'head',
        _openUri(host, port, path),
        () => _inner.head(host, port, path),
      );

  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _instrument('head', url, () => _inner.headUrl(url));

  @override
  Duration get idleTimeout => _inner.idleTimeout;

  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;

  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;

  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;

  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;

  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _inner.authenticate = f;

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => _inner.authenticateProxy = f;

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _inner.badCertificateCallback = callback;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

class _OTelHttpClientRequest implements HttpClientRequest {
  _OTelHttpClientRequest(this._inner, this._span);

  final HttpClientRequest _inner;
  final _RequestSpan _span;
  Future<HttpClientResponse>? _response;

  Future<HttpClientResponse> _track(Future<HttpClientResponse> response) =>
      response.then(
        (response) {
          _span.onResponse(response);
          return _OTelHttpClientResponse(response, _span);
        },
        onError: (Object error, StackTrace stack) {
          _span.end(error: error, stack: stack);
          return Future<HttpClientResponse>.error(error, stack);
        },
      );

  @override
  Future<HttpClientResponse> close() {
    _span.onRequestSent(_inner);
    // dart:io's close() returns `done`, so whichever is tracked first covers
    // both.
    final closing = _inner.close();
    return _response ??= _track(closing);
  }

  @override
  Future<HttpClientResponse> get done => _response ??= _track(_inner.done);

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  bool get followRedirects => _inner.followRedirects;

  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;

  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  int get contentLength => _inner.contentLength;

  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  bool get bufferOutput => _inner.bufferOutput;

  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
}

/// Ends the request's span once the body has been read, failed, or been
/// abandoned (cancel, detachSocket, redirect).
class _OTelHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _OTelHttpClientResponse(this._inner, this._span);

  final HttpClientResponse _inner;
  final _RequestSpan _span;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    var received = 0;
    final controller = StreamController<List<int>>(sync: true);
    controller.onListen = () {
      final source = _inner.listen(
        (chunk) {
          received += chunk.length;
          _span.onBodyChunk(chunk);
          controller.add(chunk);
        },
        onError: (Object error, StackTrace stack) {
          _span.end(error: error, stack: stack);
          controller.addError(error, stack);
        },
        onDone: () {
          _span.end(
            responseBodySize:
                _inner.contentLength >= 0 ? _inner.contentLength : received,
            bodyComplete: true,
          );
          controller.close();
        },
      );
      controller
        ..onPause = (() => source.pause())
        ..onResume = (() => source.resume())
        ..onCancel = () {
          _span.end(
            responseBodySize:
                _inner.contentLength >= 0 ? _inner.contentLength : null,
          );
          return source.cancel();
        };
    };
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) {
    _span.end();
    return _inner.redirect(method, url, followLoops);
  }

  @override
  Future<Socket> detachSocket() {
    _span.end();
    return _inner.detachSocket();
  }

  @override
  int get statusCode => _inner.statusCode;

  @override
  String get reasonPhrase => _inner.reasonPhrase;

  @override
  int get contentLength => _inner.contentLength;

  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  bool get isRedirect => _inner.isRedirect;

  @override
  List<RedirectInfo> get redirects => _inner.redirects;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
}

class _RequestSpan {
  _RequestSpan(this._span, this._config, this._capture);

  final Span _span;
  final HttpInstrumentationConfig _config;
  final _CapturePolicy _capture;
  int? _statusCode;
  bool _ended = false;

  /// Trace headers this SDK added, left out of captured request headers.
  final Set<String> _injected = <String>{};

  /// The response body so far, when it is one `captureResponseBodies` keeps.
  BytesBuilder? _body;

  void injectHeaders(
    HttpClientRequest request,
    TextMapPropagator<Map<String, String>, String> propagator,
  ) {
    try {
      final carrier = <String, String>{};
      propagator.inject(
        Context.current.withSpan(_span),
        carrier,
        _MapSetter(carrier),
      );
      carrier.forEach((name, value) {
        request.headers.set(name, value);
        _injected.add(name.toLowerCase());
      });
    } catch (_) {}
  }

  void onRequestSent(HttpClientRequest request) {
    if (_ended) return;
    try {
      final attributes = <String, Object>{};
      if (_config.captureRequestBodySize && request.contentLength >= 0) {
        attributes['http.request.body.size'] = request.contentLength;
      }
      if (_capture.requestHeaders) {
        _addHeaders(attributes, 'request', request.headers, skip: _injected);
      }
      if (attributes.isNotEmpty) _span.addAttributes(attributes.toAttributes());
    } catch (_) {}
  }

  void onResponse(HttpClientResponse response) {
    if (_ended) return;
    try {
      _statusCode = response.statusCode;
      final attributes = <String, Object>{
        'http.response.status_code': response.statusCode,
      };
      if (_capture.responseHeaders) {
        _addHeaders(attributes, 'response', response.headers);
      }
      _span.addAttributes(attributes.toAttributes());
    } catch (_) {}
    try {
      // Still-compressed bytes (autoUncompress off) aren't text.
      if (_capture.responseBodies &&
          response.compressionState !=
              HttpClientResponseCompressionState.compressed &&
          isCapturedBodyType(
            response.headers[HttpHeaders.contentTypeHeader]?.first,
          )) {
        _body = BytesBuilder();
      }
    } catch (_) {}
  }

  /// Keeps a copy of the first [maxCapturedBodyBytes] the app receives.
  void onBodyChunk(List<int> chunk) {
    final body = _body;
    if (body == null || _ended) return;
    try {
      final room = maxCapturedBodyBytes - body.length;
      if (room <= 0) return;
      // BytesBuilder copies, so the app may reuse its buffers.
      body.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
    } catch (_) {
      _body = null;
    }
  }

  void end({
    int? responseBodySize,
    bool bodyComplete = false,
    Object? error,
    StackTrace? stack,
  }) {
    if (_ended) return;
    _ended = true;
    try {
      final attributes = <String, Object>{};
      if (responseBodySize != null && _config.captureResponseBodySize) {
        attributes['http.response.body.size'] = responseBodySize;
      }
      final body = _body;
      _body = null;
      // A body the app stopped reading (cancel, redirect) is left out.
      if (body != null && bodyComplete && error == null) {
        final text = utf8.decode(body.takeBytes(), allowMalformed: true).trim();
        if (text.isNotEmpty) attributes['http.response.body'] = text;
      }
      if (attributes.isNotEmpty) _span.addAttributes(attributes.toAttributes());
    } catch (_) {}
    try {
      final statusCode = _statusCode;
      if (error != null) {
        _span.recordException(error, stackTrace: stack);
        _span.setStatus(SpanStatusCode.Error, error.toString());
        _span.addAttributes(
          <String, Object>{
            'error.type': error.runtimeType.toString(),
          }.toAttributes(),
        );
      } else if (statusCode != null && statusCode >= 400) {
        _span.setStatus(SpanStatusCode.Error, 'HTTP $statusCode');
      } else {
        _span.setStatus(SpanStatusCode.Ok);
      }
      _span.end();
    } catch (_) {}
  }

  /// `http.{type}.header.<name>`: every header, or the allowlist, minus
  /// `ignoreHeaders` and [skip]. Values of a repeated header are joined.
  void _addHeaders(
    Map<String, Object> attributes,
    String type,
    HttpHeaders headers, {
    Set<String> skip = const <String>{},
  }) {
    void add(String name, List<String> values) {
      final lower = name.toLowerCase();
      if (values.isEmpty || skip.contains(lower)) return;
      final key = _capture.capture.headerKey(type, lower);
      if (key == null) return;
      attributes[key] = headerAttributeValue(lower, values.join(', '));
    }

    final names = _capture.headerNames;
    if (names == null) {
      headers.forEach(add);
    } else {
      for (final name in names) {
        final values = headers[name];
        if (values != null) add(name, values);
      }
    }
  }
}

class _MapSetter implements TextMapSetter<String> {
  _MapSetter(this._carrier);

  final Map<String, String> _carrier;

  @override
  void set(String key, String value) => _carrier[key] = value;
}

const String _eventType = 'event.type';

bool _isIgnored(Uri url, HttpInstrumentationConfig config) {
  final shouldInstrument = config.shouldInstrument;
  if (shouldInstrument != null && !shouldInstrument(url)) return true;
  // The SDK's own OTLP exports, or every export would produce a span.
  final full = url.toString();
  return defaultIgnoredUrls.any((pattern) => pattern.hasMatch(full));
}

/// The attributes `OTelHttpClient` puts on its spans.
Map<String, Object> _requestAttributes(
  String method,
  Uri url,
  HttpInstrumentationConfig config,
) {
  final full = url.toString();
  return <String, Object>{
    'http.request.method': method.toUpperCase(),
    'url.full':
        full.length <= config.maxUrlLength
            ? full
            : '${full.substring(0, config.maxUrlLength)}...',
    'url.scheme': url.scheme,
    'server.address': url.host,
    _eventType: 'xhr',
    if (url.hasPort && url.port != 80 && url.port != 443)
      'server.port': url.port,
    if (url.path.isNotEmpty) 'url.path': url.path,
    if (url.query.isNotEmpty) 'url.query': url.query,
    ...?config.customAttributes?.call(url),
  };
}

/// `{METHOD} {host}{path}`, as `OTelHttpClient` and the browser SDK name
/// HTTP spans. It's also the key the opt-in wrappers' spans are matched on.
String _httpSpanName(String method, Uri url) {
  final verb = method.isEmpty ? 'HTTP' : method.toUpperCase();
  final host = url.hasPort ? '${url.host}:${url.port}' : url.host;
  if (host.isEmpty) return verb;
  final path = url.path.isEmpty ? '/' : url.path;
  return '$verb $host$path';
}

TextMapPropagator<Map<String, String>, String> _propagatorFor(
  TracePropagationFormat format,
) => CompositePropagator<Map<String, String>, String>([
  if (format != TracePropagationFormat.b3) ...[
    W3CTraceContextPropagator(),
    W3CBaggagePropagator(),
  ],
  if (format != TracePropagationFormat.w3c) ...[
    B3Propagator(),
    B3Propagator(injectEncoding: B3InjectEncoding.multi),
  ],
]);

/// The URL `HttpClient.open` requests: plain http, `path` may carry a query.
Uri _openUri(String host, int port, String path) {
  final fragment = path.indexOf('#');
  if (fragment >= 0) path = path.substring(0, fragment);
  final query = path.indexOf('?');
  return Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: query < 0 ? path : path.substring(0, query),
    query: query < 0 ? null : path.substring(query + 1),
  );
}
