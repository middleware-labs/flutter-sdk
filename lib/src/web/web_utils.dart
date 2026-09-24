// Licensed under the Apache License, Version 2.0

// Pure-Dart helpers for the Flutter web instrumentation. Nothing in here
// touches the browser, so it compiles (and is unit-tested) on the VM too.
//
// Behaviour and attribute names mirror the browser SDK
// (rum-agents/agent-browser) so bifrost reads Flutter web spans exactly like
// spans from `@middleware.io/browser`.

import 'dart:convert';
import 'dart:math' as math;

/// Browser-SDK span/log message limits.
const int messageLimit = 1024;
const int stackLimit = 4096;

String limitLen(String s, int limit) =>
    s.length > limit ? s.substring(0, limit) : s;

// ---------------------------------------------------------------------------
// URLs and span names
// ---------------------------------------------------------------------------

/// `host + path` for [url] (resolved against [base]), with the query string
/// and fragment dropped. Span names must be low cardinality, and a raw URL
/// leaks tokens/PII into an indexed field. Null when [url] can't be parsed.
String? computeUrlHostPath(String? url, {String? base}) {
  if (url == null || url.isEmpty) return null;
  try {
    var parsed = Uri.parse(url);
    if (!parsed.hasScheme && base != null) {
      parsed = Uri.parse(base).resolveUri(parsed);
    }
    final host = parsed.hasAuthority ? parsed.authority : '';
    var path = parsed.path;
    if (path.isNotEmpty && !path.startsWith('/')) path = '/$path';
    final hostPath = '$host$path';
    return hostPath.isEmpty ? null : hostPath;
  } catch (_) {
    return null;
  }
}

/// OTel-shaped HTTP client span name: `{METHOD} {host}{path}`, degrading to
/// `{METHOD}` when the URL is unparseable.
String computeHttpSpanName(String? method, String? url, {String? base}) {
  final verb =
      (method == null || method.isEmpty ? 'HTTP' : method).toUpperCase();
  final hostPath = computeUrlHostPath(url, base: base);
  return hostPath == null ? verb : '$verb $hostPath';
}

/// Resolves [url] against [base] into an absolute URL string.
String resolveUrl(String url, String base) {
  try {
    return Uri.parse(base).resolve(url).toString();
  } catch (_) {
    return url;
  }
}

/// True when [url] matches any of [patterns].
bool isUrlIgnored(String url, List<Pattern> patterns) {
  for (final p in patterns) {
    if (p is RegExp) {
      if (p.hasMatch(url)) return true;
    } else if (p is String) {
      if (url == p) return true;
    } else if (p.allMatches(url).isNotEmpty) {
      return true;
    }
  }
  return false;
}

/// Telemetry the SDK sends to the collector must never be instrumented, or
/// every export would produce a span that is itself exported.
final List<RegExp> defaultIgnoredUrls = <RegExp>[
  RegExp(r'/v1/metrics', caseSensitive: false),
  RegExp(r'/v1/traces', caseSensitive: false),
  RegExp(r'/v1/logs', caseSensitive: false),
];

/// Whether trace headers should be injected into a request to [url] made from
/// a page at [pageOrigin]. Same-origin requests always propagate; cross-origin
/// ones only when a [targets] pattern matches (CORS preflights reject unknown
/// headers, so propagating everywhere would break third-party APIs).
bool shouldPropagateTraceHeaders(
  String url,
  String pageOrigin,
  List<Pattern> targets,
) {
  try {
    final u = Uri.parse(url);
    if (u.hasScheme && u.origin == pageOrigin) return true;
  } catch (_) {
    // fall through to the pattern check
  }
  return isUrlIgnored(url, targets);
}

// ---------------------------------------------------------------------------
// Resource classification (PerformanceResourceTiming)
// ---------------------------------------------------------------------------

/// `resource.type` for a resource entry, from its initiatorType and path.
String computeResourceType(String initiatorType, String url) {
  String path;
  try {
    path = Uri.parse(url).path;
  } catch (_) {
    return 'other';
  }
  switch (initiatorType) {
    case 'initial_document':
      return 'document';
    case 'xmlhttprequest':
      return 'xhr';
    case 'fetch':
      return 'fetch';
    case 'beacon':
      return 'beacon';
  }
  if (RegExp(r'\.css$', caseSensitive: false).hasMatch(path)) return 'css';
  if (RegExp(r'\.js$', caseSensitive: false).hasMatch(path)) return 'js';
  if (const ['image', 'img', 'icon'].contains(initiatorType) ||
      RegExp(
        r'\.(gif|jpg|jpeg|tiff|png|svg|ico)$',
        caseSensitive: false,
      ).hasMatch(path)) {
    return 'image';
  }
  if (RegExp(r'\.(woff|eot|woff2|ttf)$', caseSensitive: false).hasMatch(path)) {
    return 'font';
  }
  if (const ['audio', 'video'].contains(initiatorType) ||
      RegExp(r'\.(mp3|mp4)$', caseSensitive: false).hasMatch(path)) {
    return 'media';
  }
  return 'other';
}

/// `resource.provider.type`: first-party, cdn, analytics, social or other.
String computeResourceProviderType(String url, String pageHostname) {
  final String host;
  try {
    host = Uri.parse(url).host;
  } catch (_) {
    return 'other';
  }
  if (host == pageHostname) return 'first-party';
  if (host.contains('cdn')) return 'cdn';
  if (host.contains('analytics')) return 'analytics';
  if (host.contains('social')) return 'social';
  return 'other';
}

/// The subset of a PerformanceResourceTiming entry the attribute helpers read.
/// Times are in ms on the performance clock; 0 means "not exposed".
class ResourceTimingData {
  const ResourceTimingData({
    this.name = '',
    this.initiatorType = '',
    this.startTime = 0,
    this.duration = 0,
    this.workerStart = 0,
    this.redirectStart = 0,
    this.redirectEnd = 0,
    this.fetchStart = 0,
    this.domainLookupStart = 0,
    this.domainLookupEnd = 0,
    this.connectStart = 0,
    this.secureConnectionStart = 0,
    this.connectEnd = 0,
    this.requestStart = 0,
    this.responseStart = 0,
    this.responseEnd = 0,
    this.transferSize = 0,
    this.encodedBodySize = 0,
    this.decodedBodySize = 0,
    this.responseStatus = 0,
    this.nextHopProtocol = '',
  });

  final String name;
  final String initiatorType;
  final double startTime;
  final double duration;
  final double workerStart;
  final double redirectStart;
  final double redirectEnd;
  final double fetchStart;
  final double domainLookupStart;
  final double domainLookupEnd;
  final double connectStart;
  final double secureConnectionStart;
  final double connectEnd;
  final double requestStart;
  final double responseStart;
  final double responseEnd;
  final num transferSize;
  final num encodedBodySize;
  final num decodedBodySize;
  final int responseStatus;
  final String nextHopProtocol;

  /// Performance-timeline marker names, in the order the upstream OTel
  /// `addSpanNetworkEvents` emits them as span events.
  Map<String, double> get networkEvents => <String, double>{
    'fetchStart': fetchStart,
    'domainLookupStart': domainLookupStart,
    'domainLookupEnd': domainLookupEnd,
    'connectStart': connectStart,
    'secureConnectionStart': secureConnectionStart,
    'connectEnd': connectEnd,
    'requestStart': requestStart,
    'responseStart': responseStart,
    'responseEnd': responseEnd,
  };
}

bool _isPositive(num? v) => v != null && v > 0;

void _setPhase(
  Map<String, Object> out,
  String name,
  double start,
  double end,
) {
  if (_isPositive(start) && end >= start) out[name] = end - start;
}

/// `resource.*` size and timing attributes shared by the document-load, fetch
/// and XHR instrumentations.
///
/// Phase markers are 0 when a cross-origin response fails the
/// Timing-Allow-Origin check; subtracting those zeroes would turn a timestamp
/// into a bogus duration, so phases are omitted instead and
/// `resource.timing_visible=false` is emitted.
Map<String, Object> resourceTimingAttributes(ResourceTimingData r) {
  final out = <String, Object>{
    'resource.size': r.decodedBodySize,
    'resource.transfer_size': r.transferSize,
    'resource.nextHopProtocol': r.nextHopProtocol,
  };
  // transferSize 0 with a decoded body means a cache hit.
  if (r.transferSize == 0 && _isPositive(r.decodedBodySize)) {
    out['resource.cache_hit'] = true;
  }
  // workerStart is non-zero only when a service worker handled the request.
  if (_isPositive(r.workerStart)) {
    out['resource.service_worker'] = true;
    _setPhase(
      out,
      'resource.worker_startup.duration',
      r.workerStart,
      r.fetchStart,
    );
  }

  final timingVisible =
      _isPositive(r.requestStart) && _isPositive(r.responseStart);
  if (!timingVisible) {
    out['resource.timing_visible'] = false;
    _setPhase(out, 'resource.duration', r.startTime, r.responseEnd);
    return out;
  }

  _setPhase(out, 'resource.duration', r.requestStart, r.responseEnd);
  _setPhase(out, 'resource.connect.duration', r.connectStart, r.connectEnd);
  _setPhase(
    out,
    'resource.dns.duration',
    r.domainLookupStart,
    r.domainLookupEnd,
  );
  _setPhase(
    out,
    'resource.first_byte.duration',
    r.requestStart,
    r.responseStart,
  );
  _setPhase(
    out,
    'resource.download.duration',
    r.responseStart,
    r.responseEnd,
  );
  // No TLS handshake / no redirect is a true zero, not a missing value.
  if (_isPositive(r.secureConnectionStart)) {
    _setPhase(
      out,
      'resource.ssl.duration',
      r.secureConnectionStart,
      r.connectEnd,
    );
  } else {
    out['resource.ssl.duration'] = 0;
  }
  if (_isPositive(r.redirectStart)) {
    _setPhase(
      out,
      'resource.redirect.duration',
      r.redirectStart,
      r.redirectEnd,
    );
  } else {
    out['resource.redirect.duration'] = 0;
  }
  return out;
}

/// Status attributes of a resource the page loaded. A 0 status (withheld by
/// the browser) stays on `resource.status_code` but is kept off the HTTP key,
/// where it would read as a real status.
Map<String, Object> resourceStatusAttributes(ResourceTimingData r) => {
  'resource.status_code': r.responseStatus,
  if (r.responseStatus > 0) 'http.response.status_code': r.responseStatus,
};

// ---------------------------------------------------------------------------
// Browser / bot detection
// ---------------------------------------------------------------------------

final RegExp _botUserAgent = RegExp(
  r'(googlebot|google-read-aloud|read-aloud|adsbot-google|mediapartners-google|apis-google|feedfetcher-google|bingbot|bingpreview|yandex(bot)?|baiduspider|duckduckbot|slurp|sogou|exabot|facebookexternalhit|facebot|ia_archiver|linkedinbot|twitterbot|slackbot|telegrambot|discordbot|whatsapp|embedly|quora link preview|pinterest(bot)?|redditbot|applebot|petalbot|semrushbot|ahrefsbot|mj12bot|dotbot|bytespider|amazonbot|gptbot|oai-searchbot|chatgpt-user|claudebot|anthropic-ai|perplexitybot|ccbot|dataforseobot|screaming frog|lighthouse|chrome-lighthouse|pagespeed|gtmetrix|pingdom|uptimerobot|statuscake|headlesschrome|headless|phantomjs|puppeteer|playwright|selenium|webdriver|crawler|spider|crawling|\bbot\b)',
  caseSensitive: false,
);

/// True for crawler / headless / monitoring user agents.
bool isBotUserAgent(String? userAgent) =>
    userAgent != null && userAgent.isNotEmpty && _botUserAgent.hasMatch(userAgent);

const List<(String, String)> _browsers = [
  ('UCBrowser', r'(ucbrowser)'),
  ('Edge', r'(edge|edga|edgios|edg)'),
  ('GoogleBot', r'(googlebot)'),
  ('Chromium', r'(chromium)'),
  ('Firefox', r'(firefox|fxios)'),
  ('Chrome', r'(chrome|crios)'),
  ('Safari', r'(safari)'),
  ('Opera', r'(opera|opr)'),
];

/// `(browser.name, browser.version)` parsed from a user agent, using the same
/// precedence as the browser SDK so both report identical values.
({String name, String version}) browserInfo(String userAgent) {
  for (final (name, pattern) in _browsers) {
    if (RegExp(pattern, caseSensitive: false).hasMatch(userAgent)) {
      final version = RegExp(
        '$pattern\\/([\\d\\.]+)',
        caseSensitive: false,
      ).firstMatch(userAgent);
      return (name: name, version: version?.group(2) ?? '0.0.0.0');
    }
  }
  return (name: 'unknown', version: '0.0.0.0');
}

/// OS name from `navigator.platform` / user agent, matching the browser SDK.
String? browserOs(String platform, String userAgent) {
  const mac = ['Macintosh', 'MacIntel', 'MacPPC', 'Mac68K'];
  const win = ['Win32', 'Win64', 'Windows', 'WinCE'];
  const ios = ['iPhone', 'iPad', 'iPod'];
  if (mac.contains(platform)) return 'Mac OS';
  if (ios.contains(platform)) return 'iOS';
  if (win.contains(platform)) return 'Windows';
  if (userAgent.contains('Android')) return 'Android';
  if (platform.contains('Linux')) return 'Linux';
  return null;
}

const List<String> _extensionUrlPrefixes = [
  'chrome-extension://',
  'moz-extension://',
  'safari-extension://',
];

/// Errors and console output from browser extensions are not the app's.
bool shouldIgnoreMessage(String? text) {
  if (text == null || text.isEmpty) return false;
  final scan = text.length > 8192 ? text.substring(0, 8192) : text;
  return _extensionUrlPrefixes.any(scan.contains);
}

/// A message worth reporting: non-blank and not an `[object ...]` dump.
bool isUsefulMessage(String? s) =>
    s != null &&
    s.trim().isNotEmpty &&
    !s.startsWith('[object') &&
    s != 'error';

// ---------------------------------------------------------------------------
// Web vitals
// ---------------------------------------------------------------------------

/// `largestShiftTarget` -> `largest_shift_target`.
String toSnakeCase(String key) => key
    .replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (m) => '${m[1]}_${m[2]}',
    )
    .replaceAllMapped(
      RegExp(r'([A-Z]+)([A-Z][a-z])'),
      (m) => '${m[1]}_${m[2]}',
    )
    .toLowerCase();

/// `good` / `needs-improvement` / `poor`, using the web-vitals thresholds.
String webVitalRating(String metric, num value) {
  const thresholds = <String, (num, num)>{
    'LCP': (2500, 4000),
    'FCP': (1800, 3000),
    'CLS': (0.1, 0.25),
    'INP': (200, 500),
    'TTFB': (800, 1800),
  };
  final t = thresholds[metric];
  if (t == null) return 'good';
  if (value > t.$2) return 'poor';
  if (value > t.$1) return 'needs-improvement';
  return 'good';
}

/// Cumulative Layout Shift using the web-vitals session-window algorithm:
/// shifts within 1s of each other and inside a 5s window are summed, and the
/// largest window wins.
class ClsAccumulator {
  double _sessionValue = 0;
  double? _firstTs;
  double? _lastTs;
  double value = 0;

  /// Largest single shift of the worst window, for attribution.
  double largestShiftValue = 0;
  double largestShiftTime = 0;
  String? largestShiftTarget;

  double _windowLargestValue = 0;
  double _windowLargestTime = 0;
  String? _windowLargestTarget;

  /// Adds one layout-shift entry; returns true when CLS grew.
  bool add(double shiftValue, double startTime, {String? target}) {
    if (_firstTs != null &&
        _lastTs != null &&
        startTime - _lastTs! < 1000 &&
        startTime - _firstTs! < 5000) {
      _sessionValue += shiftValue;
    } else {
      _sessionValue = shiftValue;
      _firstTs = startTime;
      _windowLargestValue = 0;
    }
    _lastTs = startTime;
    if (shiftValue > _windowLargestValue) {
      _windowLargestValue = shiftValue;
      _windowLargestTime = startTime;
      _windowLargestTarget = target;
    }
    if (_sessionValue > value) {
      value = _sessionValue;
      largestShiftValue = _windowLargestValue;
      largestShiftTime = _windowLargestTime;
      largestShiftTarget = _windowLargestTarget;
      return true;
    }
    return false;
  }
}

/// Interaction to Next Paint: the longest event duration per interactionId,
/// reported at the ~98th percentile (one outlier skipped per 50 interactions),
/// as web-vitals does.
class InpAccumulator {
  final Map<int, InpInteraction> _byId = <int, InpInteraction>{};
  int interactionCount = 0;

  void add(InpInteraction entry) {
    if (entry.interactionId == 0) return;
    final existing = _byId[entry.interactionId];
    if (existing == null) {
      interactionCount++;
      _byId[entry.interactionId] = entry;
    } else if (entry.duration > existing.duration) {
      _byId[entry.interactionId] = entry;
    }
  }

  /// The interaction INP is currently reporting, or null when none happened.
  InpInteraction? get worst {
    if (_byId.isEmpty) return null;
    final sorted = _byId.values.toList()
      ..sort((a, b) => b.duration.compareTo(a.duration));
    final skip = math.min(sorted.length - 1, interactionCount ~/ 50);
    return sorted[skip];
  }
}

class InpInteraction {
  const InpInteraction({
    required this.interactionId,
    required this.duration,
    required this.startTime,
    required this.processingStart,
    required this.processingEnd,
    required this.name,
    this.target,
  });

  final int interactionId;
  final double duration;
  final double startTime;
  final double processingStart;
  final double processingEnd;
  final String name;
  final String? target;

  /// web-vitals INP attribution fields (camelCase; callers snake_case them).
  Map<String, Object> get attribution {
    final nextPaint = startTime + duration;
    return <String, Object>{
      'interactionType': name.startsWith('key') ? 'keyboard' : 'pointer',
      'interactionTime': startTime,
      'nextPaintTime': nextPaint,
      'inputDelay': math.max(0, processingStart - startTime),
      'processingDuration': math.max(0, processingEnd - processingStart),
      'presentationDelay': math.max(0, nextPaint - processingEnd),
      if (target != null) 'interactionTarget': target!,
    };
  }
}

// ---------------------------------------------------------------------------
// Frustration signals and click -> network attribution
// ---------------------------------------------------------------------------

/// Rage click: [clickCount] clicks, each within [thresholdPx] and [timeout] of
/// the previous one (browser SDK defaults: 4 clicks, 30px, 1s).
class RageClickDetector {
  RageClickDetector({
    this.thresholdPx = 30,
    this.timeout = const Duration(seconds: 1),
    this.clickCount = 4,
  });

  final double thresholdPx;
  final Duration timeout;
  final int clickCount;
  final List<(double, double, int)> _clicks = [];

  /// Registers a click at ([x], [y]); true when it completes a rage click.
  bool isRageClick(double x, double y, {DateTime? now}) {
    final ts = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final last = _clicks.isEmpty ? null : _clicks.last;
    if (last != null &&
        ts - last.$3 < timeout.inMilliseconds &&
        math.sqrt(math.pow(x - last.$1, 2) + math.pow(y - last.$2, 2)) <
            thresholdPx) {
      _clicks.add((x, y, ts));
      if (_clicks.length >= clickCount) {
        _clicks.clear();
        return true;
      }
    } else {
      _clicks
        ..clear()
        ..add((x, y, ts));
    }
    return false;
  }
}

class _Interaction {
  _Interaction(this.traceId, this.spanId, this.name, this.startedAt, int window)
    : expiresAt = startedAt + window;
  final String traceId;
  final String spanId;
  final String? name;
  final int startedAt;
  final int expiresAt;
}

/// Click -> network attribution by time window (not a real parent edge): a
/// request that *starts* within [window] of a click gets that click's ids as
/// `interaction.trace_id` / `interaction.span_id` / `interaction.name`.
class InteractionContext {
  InteractionContext._();

  static const Duration window = Duration(seconds: 1);
  static const int _maxTracked = 5;
  static final List<_Interaction> _recent = [];

  static void setActiveInteraction(
    String traceId,
    String spanId, {
    String? name,
    DateTime? startedAt,
  }) {
    _recent.add(
      _Interaction(
        traceId,
        spanId,
        name,
        (startedAt ?? DateTime.now()).millisecondsSinceEpoch,
        window.inMilliseconds,
      ),
    );
    if (_recent.length > _maxTracked) _recent.removeAt(0);
  }

  /// Attributes for a network span that started at [startedAt], if a recent
  /// interaction covers it.
  static Map<String, Object> attributesAt(DateTime startedAt) {
    final at = startedAt.millisecondsSinceEpoch;
    for (var i = _recent.length - 1; i >= 0; i--) {
      final it = _recent[i];
      if (at >= it.startedAt && at <= it.expiresAt) {
        return {
          'interaction.trace_id': it.traceId,
          'interaction.span_id': it.spanId,
          if (it.name != null) 'interaction.name': it.name!,
        };
      }
    }
    return const {};
  }

  static void clear() => _recent.clear();
}

// ---------------------------------------------------------------------------
// JS stack parsing (port of error-stack-parser, V8 + Firefox/Safari)
// ---------------------------------------------------------------------------

final RegExp _chromeStack = RegExp(r'^\s*at .*(\S+:\d+|\(native\))', multiLine: true);
final RegExp _safariNative = RegExp(r'^(eval@)?(\[native code])?$');

List<String?> _extractLocation(String urlLike) {
  if (!urlLike.contains(':')) return [urlLike, null, null];
  final m = RegExp(
    r'(.+?)(?::(\d+))?(?::(\d+))?$',
  ).firstMatch(urlLike.replaceAll(RegExp(r'[()]'), ''));
  if (m == null) return [urlLike, null, null];
  return [m[1], m[2], m[3]];
}

Map<String, Object> _frame({
  String? functionName,
  String? fileName,
  String? lineNumber,
  String? columnNumber,
  required String source,
}) => <String, Object>{
  if (functionName != null && functionName.isNotEmpty)
    'functionName': functionName,
  if (fileName != null) 'fileName': fileName,
  if (lineNumber != null) 'lineNumber': int.tryParse(lineNumber) ?? lineNumber,
  if (columnNumber != null)
    'columnNumber': int.tryParse(columnNumber) ?? columnNumber,
  'source': source,
};

/// Parses a JS `Error.stack` into the same frame objects the browser SDK
/// sends as `error.structuredStack` (the sourcemap service reads these).
List<Map<String, Object>> parseJsStack(String? stack) {
  if (stack == null || stack.isEmpty) return const [];
  if (_chromeStack.hasMatch(stack)) {
    return stack.split('\n').where(_chromeStack.hasMatch).map((raw) {
      var line = raw;
      if (line.contains('(eval ')) {
        line = line
            .replaceAll('eval code', 'eval')
            .replaceAll(RegExp(r'(\(eval at [^()]*)|(,.*$)'), '');
      }
      var sanitized = line
          .replaceFirst(RegExp(r'^\s+'), '')
          .replaceAll('(eval code', '(')
          .replaceFirst(RegExp(r'^.*?\s+'), '');
      final location = RegExp(r' (\(.+\)$)').firstMatch(sanitized);
      if (location != null) {
        sanitized = sanitized.replaceFirst(location[0]!, '');
      }
      final parts = _extractLocation(location != null ? location[1]! : sanitized);
      final fileName =
          const ['eval', '<anonymous>'].contains(parts[0]) ? null : parts[0];
      return _frame(
        functionName: location != null ? sanitized : null,
        fileName: fileName,
        lineNumber: parts[1],
        columnNumber: parts[2],
        source: raw,
      );
    }).toList();
  }
  return stack
      .split('\n')
      .where((l) => !_safariNative.hasMatch(l))
      .map((raw) {
        var line = raw;
        if (line.contains(' > eval')) {
          line = line.replaceAllMapped(
            RegExp(r' line (\d+)(?: > eval line \d+)* > eval:\d+:\d+'),
            (m) => ':${m[1]}',
          );
        }
        if (!line.contains('@') && !line.contains(':')) {
          return _frame(functionName: line, source: raw);
        }
        final fnRegex = RegExp(r'((.*".+"[^@]*)?[^@]*)(?:@)');
        final m = fnRegex.firstMatch(line);
        final parts = _extractLocation(line.replaceFirst(fnRegex, ''));
        return _frame(
          functionName: m?[1],
          fileName: parts[0],
          lineNumber: parts[1],
          columnNumber: parts[2],
          source: raw,
        );
      })
      .toList();
}

/// `exception.stack_details` payload derived from parsed frames.
List<Map<String, Object?>> exceptionStackFrames(
  List<Map<String, Object>> frames,
) => frames
    .map(
      (f) => <String, Object?>{
        'exception.line': f['lineNumber'],
        'exception.function_name': f['functionName'],
        'exception.function_body': f['source'],
        'exception.column_number': f['columnNumber'],
        'exception.file': f['fileName'],
      },
    )
    .toList();

/// JSON-encodes [value], never throwing.
String safeJson(Object? value) {
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}
