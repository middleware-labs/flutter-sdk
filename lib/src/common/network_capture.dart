// Licensed under the Apache License, Version 2.0

// Opt-in header and response-body capture on network spans, shared by the
// Flutter web (fetch/XHR) and dart:io instrumentations. Mirrors the browser
// SDK's `captureNetworkHeaders` / `captureResponseBodies` / `ignoreHeaders`.

import 'package:meta/meta.dart' show internal;

/// What the network instrumentation records beyond status, sizes and timings.
@internal
class NetworkCapture {
  NetworkCapture({
    this.headers = false,
    this.responseBodies = false,
    Iterable<String> ignoreHeaders = const <String>[],
  }) : ignoreHeaders = ignoreHeaders.map((h) => h.toLowerCase()).toSet();

  /// Request and response headers as `http.{request|response}.header.<n>`.
  final bool headers;

  /// JSON and plain-text response bodies as `http.response.body`.
  final bool responseBodies;

  /// Lowercased header names never recorded.
  final Set<String> ignoreHeaders;

  static final NetworkCapture none = NetworkCapture();

  /// The attribute for header [name], or null when it's ignored.
  String? headerKey(String type, String name) {
    final lower = name.toLowerCase();
    if (ignoreHeaders.contains(lower)) return null;
    return headerAttributeKey(type, lower);
  }
}

/// What the browser SDK records in place of an `x-access-token` value.
const String maskedHeaderValue = '********';

/// `http.{type}.header.<name>`: lowercased, `-` replaced with `_`.
String headerAttributeKey(String type, String name) =>
    'http.$type.header.${name.toLowerCase().replaceAll('-', '_')}';

/// [value], unless [name] carries a credential the SDK never records.
String headerAttributeValue(String name, String value) =>
    name.toLowerCase() == 'x-access-token' ? maskedHeaderValue : value;

String _baseContentType(String? type) {
  if (type == null) return '';
  final semicolon = type.indexOf(';');
  return (semicolon < 0 ? type : type.substring(0, semicolon))
      .trim()
      .toLowerCase();
}

/// `application/json`, plus structured-syntax types such as
/// `application/problem+json`.
bool isJsonContentType(String? type) {
  final base = _baseContentType(type);
  return base == 'application/json' || base.endsWith('+json');
}

/// Response bodies `captureResponseBodies` records: JSON and plain text.
bool isCapturedBodyType(String? type) =>
    isJsonContentType(type) || _baseContentType(type) == 'text/plain';
