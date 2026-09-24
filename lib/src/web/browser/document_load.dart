// Licensed under the Apache License, Version 2.0

import 'dart:async';
import 'dart:js_interop';

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

import '../web_telemetry.dart';
import '../web_utils.dart';
import 'js_helpers.dart';

const _scope = '@opentelemetry/instrumentation-document-load';

/// Network requests have their own spans (fetch / XHR instrumentation).
const _excludedInitiatorTypes = {'beacon', 'fetch', 'xmlhttprequest'};

const _rootEvents = [
  'fetchStart',
  'unloadEventStart',
  'unloadEventEnd',
  'domInteractive',
  'domContentLoadedEventStart',
  'domContentLoadedEventEnd',
  'domComplete',
  'loadEventStart',
  'loadEventEnd',
];

const _navigationKeys = [
  'fetchStart',
  'unloadEventStart',
  'unloadEventEnd',
  'redirectStart',
  'redirectEnd',
  'domainLookupStart',
  'domainLookupEnd',
  'connectStart',
  'secureConnectionStart',
  'connectEnd',
  'requestStart',
  'responseStart',
  'responseEnd',
  'domInteractive',
  'domContentLoadedEventStart',
  'domContentLoadedEventEnd',
  'domComplete',
  'loadEventStart',
  'loadEventEnd',
  'transferSize',
  'encodedBodySize',
  'decodedBodySize',
  'redirectCount',
];

/// Port of the browser SDK's document-load instrumentation: a `documentLoad`
/// trace (Navigation Timing) with a `documentFetch` child and one
/// `resourceFetch`-style child per resource loaded before `loadEventEnd`.
///
/// Flutter web keeps loading after the load event (CanvasKit, fonts, assets),
/// so resources that start later are reported too, as root spans flagged
/// `resource.post_load=true` — both from the initial sweep and, afterwards,
/// from a live PerformanceObserver.
class DocumentLoadInstrumentation {
  DocumentLoadInstrumentation({required this.ignoreUrls});

  final List<Pattern> ignoreUrls;
  final List<Disposer> _disposers = [];
  bool _collected = false;

  void enable() {
    final nav = _navigationEntry();
    if (nav != null && jsNum0(nav, 'loadEventEnd') > 0) {
      Timer.run(_collect);
    } else {
      // loadEventEnd is only recorded once every load handler has returned.
      _disposers.add(
        listen(jsWindow, 'load', (_) => Timer(Duration.zero, _collect)),
      );
    }
  }

  void disable() {
    for (final d in _disposers) {
      d();
    }
    _disposers.clear();
  }

  JSObject? _navigationEntry() {
    final entries = performanceEntriesByType('navigation');
    return entries.isEmpty ? null : entries.first;
  }

  void _collect() {
    if (_collected) return;
    _collected = true;
    final origin = timeOrigin;
    final nav = _navigationEntry();
    double? loadEventEnd;

    if (nav != null) {
      loadEventEnd = jsNum(nav, 'loadEventEnd');
      final href = locationHref;
      final hostPath = computeUrlHostPath(href);
      final root = WebTelemetry.startSpan(
        hostPath == null ? 'documentLoad' : 'documentLoad $hostPath',
        scope: _scope,
        startTime: perfToDateTime(origin, jsNum0(nav, 'fetchStart')),
        attributes: {
          'url.full': href,
          'user_agent.original': userAgent,
          'event.type': 'load',
          ..._extraDocLoadTags(),
        },
      );
      for (final name in _rootEvents) {
        WebTelemetry.addTimelineEvent(root, name, origin, jsNum0(nav, name));
      }
      for (final paint in performanceEntriesByType('paint')) {
        final name = jsStr(paint, 'name');
        if (name == 'first-paint' || name == 'first-contentful-paint') {
          WebTelemetry.addTimelineEvent(
            root,
            name == 'first-paint' ? 'firstPaint' : 'firstContentfulPaint',
            origin,
            jsNum0(paint, 'startTime'),
          );
        }
      }

      final timing = resourceTimingOf(nav);
      final fetch = WebTelemetry.startSpan(
        'documentFetch',
        scope: _scope,
        parent: root,
        startTime: perfToDateTime(origin, timing.fetchStart),
        attributes: {
          'url.full': href,
          for (final key in _navigationKeys)
            if (jsNum(nav, key) != null) 'navigation.$key': jsNum(nav, key)!,
          ..._contentLengthAttributes(timing),
        },
      );
      _addNetworkEvents(fetch, timing, origin);
      fetch.end(endTime: perfToDateTime(origin, timing.responseEnd));

      for (final entry in performanceEntriesByType('resource')) {
        final r = resourceTimingOf(entry);
        final postLoad =
            loadEventEnd != null && loadEventEnd > 0 && r.startTime > loadEventEnd;
        _reportResource(entry, origin, parent: postLoad ? null : root);
      }

      root.end(
        endTime: perfToDateTime(
          origin,
          loadEventEnd != null && loadEventEnd > 0
              ? loadEventEnd
              : jsNum0(nav, 'domComplete'),
        ),
      );
    } else {
      for (final entry in performanceEntriesByType('resource')) {
        _reportResource(entry, origin);
      }
    }

    // Everything loaded from here on: CanvasKit, fonts, images, lazy chunks.
    // buffered:false so nothing the sweep already reported comes back.
    _disposers.add(
      observePerformance('resource', (entries) {
        for (final entry in entries) {
          _reportResource(entry, origin);
        }
      }, buffered: false),
    );
  }

  /// A resource span; root (and `resource.post_load`) when [parent] is null.
  void _reportResource(JSObject entry, double origin, {APISpan? parent}) {
    final r = resourceTimingOf(entry);
    if (_excludedInitiatorTypes.contains(r.initiatorType) ||
        r.name.isEmpty ||
        isUrlIgnored(r.name, ignoreUrls)) {
      return;
    }
    Uri? url;
    try {
      url = Uri.parse(r.name);
    } catch (_) {}
    final span = WebTelemetry.startSpan(
      computeHttpSpanName('GET', r.name),
      scope: _scope,
      parent: parent,
      startTime: perfToDateTime(
        origin,
        r.fetchStart > 0 ? r.fetchStart : r.startTime,
      ),
      attributes: {
        'url.full': r.name,
        'event.type': 'resource',
        if (parent == null) 'resource.post_load': true,
        ...resourceStatusAttributes(r),
        ...resourceTimingAttributes(r),
        'resource.type': computeResourceType(r.initiatorType, r.name),
        'resource.initiator_type': r.initiatorType,
        if (url != null) ...{
          'resource.url_path': url.path.isEmpty ? '/' : url.path,
          'resource.url': r.name,
          'resource.url_host': url.authority,
          'resource.url_scheme': '${url.scheme}:',
        },
        'resource.provider.type': computeResourceProviderType(
          r.name,
          locationHostname,
        ),
        ..._contentLengthAttributes(r),
      },
    );
    _addNetworkEvents(span, r, origin);
    span.end(
      endTime: perfToDateTime(
        origin,
        r.responseEnd > 0 ? r.responseEnd : r.startTime + r.duration,
      ),
    );
  }

  void _addNetworkEvents(APISpan span, ResourceTimingData r, double origin) {
    r.networkEvents.forEach((name, value) {
      WebTelemetry.addTimelineEvent(span, name, origin, value);
    });
  }

  Map<String, Object> _contentLengthAttributes(ResourceTimingData r) => {
    if (r.encodedBodySize > 0)
      'http.response_content_length': r.encodedBodySize,
    if (r.decodedBodySize > 0 && r.decodedBodySize != r.encodedBodySize)
      'http.response_content_length_uncompressed': r.decodedBodySize,
  };

  Map<String, Object> _extraDocLoadTags() {
    final referrer = jsStr(jsDocument, 'referrer');
    final screen = jsObj(jsWindow, 'screen');
    final w = jsNum(screen, 'width');
    final h = jsNum(screen, 'height');
    return {
      if (referrer != null && referrer.isNotEmpty) 'document.referrer': referrer,
      if (w != null && h != null) 'screen.xy': '${w.toInt()}x${h.toInt()}',
    };
  }
}
