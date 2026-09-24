// Licensed under the Apache License, Version 2.0

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    as sdk;

import '../web_telemetry.dart';
import '../web_utils.dart';
import 'js_helpers.dart';

const _scope = 'webvitals';

/// Core Web Vitals, reported with the same span names and attributes as the
/// browser SDK (which uses the `web-vitals` attribution build):
///
/// | span                        | metric |
/// |-----------------------------|--------|
/// | `largest-contentful-paint`  | LCP    |
/// | `first-contentful-paint`    | FCP    |
/// | `layout-shift`              | CLS    |
/// | `interaction-next-paint`    | INP    |
/// | `ttfb`                      | TTFB   |
///
/// All are children of a zero-length `webvitals` span, carry
/// `web_vital.{name,id,navigationType,delta,rating,value,entries}` and
/// flattened `web_vital.attribution.*` scalars. Collection follows web-vitals:
/// LCP is final at the first input or when the page is hidden, CLS and INP
/// are reported when the page is hidden (again if they grew since).
class WebVitalsInstrumentation {
  final List<Disposer> _disposers = [];
  late final sdk.Span _parent;
  late final String _navigationType;
  late final double _activationStart;
  double _firstHiddenTime = double.infinity;

  double? _ttfb;
  bool _fcpReported = false;

  JSObject? _lcpEntry;
  bool _lcpReported = false;

  final ClsAccumulator _cls = ClsAccumulator();
  final List<JSObject> _clsEntries = [];
  double? _clsReported;
  final String _clsId = _newId();

  final InpAccumulator _inp = InpAccumulator();
  double? _inpReported;
  final String _inpId = _newId();

  static final math.Random _random = math.Random();

  // web-vitals id format: v5-{timestamp}-{random}. (No `1 << 32` here: shifts
  // are 32-bit when compiled to JS.)
  static String _newId() =>
      'v5-${DateTime.now().millisecondsSinceEpoch}-'
      '${_random.nextInt(0x7fffffff)}${_random.nextInt(0xffff)}';

  void enable() {
    _parent = WebTelemetry.startSpan('webvitals', scope: _scope);
    _parent.end();

    final nav = _navigationEntry();
    _activationStart = jsNum0(nav, 'activationStart');
    _navigationType = _navigationTypeOf(nav);
    if (documentHidden) _firstHiddenTime = 0;

    _reportTtfbWhenReady();

    _disposers.add(observePerformance('paint', _onPaint));
    _disposers.add(
      observePerformance('largest-contentful-paint', (entries) {
        for (final e in entries) {
          if (jsNum0(e, 'startTime') < _firstHiddenTime) _lcpEntry = e;
        }
      }),
    );
    _disposers.add(observePerformance('layout-shift', _onLayoutShift));
    _disposers.add(
      observePerformance('event', _onEvents, durationThreshold: 40),
    );
    _disposers.add(observePerformance('first-input', _onEvents));

    // LCP stops at the first discrete input; scrolling doesn't count.
    for (final type in const ['keydown', 'click', 'pointerdown']) {
      _disposers.add(
        listen(jsWindow, type, (_) => _reportLcp(), capture: true),
      );
    }
    _disposers.add(
      listen(jsDocument, 'visibilitychange', (_) {
        if (documentHidden) _onHidden();
      }, capture: true),
    );
    _disposers.add(listen(jsWindow, 'pagehide', (_) => _onHidden()));
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

  String _navigationTypeOf(JSObject? nav) {
    if (_activationStart > 0) return 'prerender';
    final type = jsStr(nav, 'type');
    if (type == null) return 'navigate';
    return type.replaceAll('_', '-');
  }

  void _onHidden() {
    if (_firstHiddenTime == double.infinity) _firstHiddenTime = perfNow();
    _reportLcp();
    _reportCls();
    _reportInp();
  }

  String _loadState(double at) {
    final nav = _navigationEntry();
    if (nav == null) return 'complete';
    if (at < jsNum0(nav, 'domInteractive')) return 'loading';
    if (jsNum0(nav, 'domContentLoadedEventStart') == 0 ||
        at < jsNum0(nav, 'domContentLoadedEventStart')) {
      return 'dom-interactive';
    }
    if (jsNum0(nav, 'domComplete') == 0 || at < jsNum0(nav, 'domComplete')) {
      return 'dom-content-loaded';
    }
    return 'complete';
  }

  // ---- TTFB ---------------------------------------------------------------

  void _reportTtfbWhenReady() {
    final nav = _navigationEntry();
    if (nav == null) return;
    final responseStart = jsNum0(nav, 'responseStart');
    if (responseStart <= 0) return;
    final value = math.max(responseStart - _activationStart, 0.0);
    _ttfb = value;
    double rel(String key) =>
        math.max(jsNum0(nav, key) - _activationStart, 0.0);
    final waitEnd = math.max(
      (jsNum0(nav, 'workerStart') > 0
              ? jsNum0(nav, 'workerStart')
              : jsNum0(nav, 'fetchStart')) -
          _activationStart,
      0.0,
    );
    final dnsStart = rel('domainLookupStart');
    final connectStart = rel('connectStart');
    final connectEnd = rel('connectEnd');
    _report(
      name: 'ttfb',
      metric: 'TTFB',
      id: _newId(),
      value: value,
      delta: value,
      entries: [nav],
      attribution: {
        'waitingDuration': waitEnd,
        'cacheDuration': dnsStart - waitEnd,
        'dnsDuration': connectStart - dnsStart,
        'connectionDuration': connectEnd - connectStart,
        'requestDuration': value - connectEnd,
      },
    );
  }

  // ---- FCP ----------------------------------------------------------------

  void _onPaint(List<JSObject> entries) {
    if (_fcpReported) return;
    for (final e in entries) {
      if (jsStr(e, 'name') != 'first-contentful-paint') continue;
      final start = jsNum0(e, 'startTime');
      if (start >= _firstHiddenTime) return;
      _fcpReported = true;
      final value = math.max(start - _activationStart, 0.0);
      final ttfb = _ttfb ?? 0;
      _report(
        name: 'first-contentful-paint',
        metric: 'FCP',
        id: _newId(),
        value: value,
        delta: value,
        entries: [e],
        attribution: {
          'timeToFirstByte': ttfb,
          'firstByteToFCP': value - ttfb,
          'loadState': _loadState(start),
        },
      );
      return;
    }
  }

  // ---- LCP ----------------------------------------------------------------

  void _reportLcp() {
    if (_lcpReported) return;
    final entry = _lcpEntry;
    if (entry == null) return;
    _lcpReported = true;
    final start = jsNum0(entry, 'startTime');
    final value = math.max(start - _activationStart, 0.0);
    final ttfb = _ttfb ?? 0;
    final url = jsStr(entry, 'url');
    final attribution = <String, Object>{
      'timeToFirstByte': ttfb,
      if (describeNode(jsGet(entry, 'element')) case final target?)
        'target': target,
      if (url != null && url.isNotEmpty) 'url': url,
    };
    // Split the rest of LCP into load delay / load time / render delay using
    // the LCP image's resource entry (text LCP has none: all render delay).
    var loadDelay = 0.0;
    var loadDuration = 0.0;
    if (url != null && url.isNotEmpty) {
      final resources = jsList(
        jsPerformance?.callMethod<JSAny?>('getEntriesByName'.toJS, url.toJS),
      );
      if (resources.isNotEmpty) {
        final r = resources.first;
        final loadStart = math.max(
          ttfb,
          (jsNum0(r, 'requestStart') > 0
                  ? jsNum0(r, 'requestStart')
                  : jsNum0(r, 'startTime')) -
              _activationStart,
        );
        final loadEnd = math.min(
          value,
          math.max(loadStart, jsNum0(r, 'responseEnd') - _activationStart),
        );
        loadDelay = loadStart - ttfb;
        loadDuration = loadEnd - loadStart;
      }
    }
    attribution['resourceLoadDelay'] = loadDelay;
    attribution['resourceLoadDuration'] = loadDuration;
    attribution['elementRenderDelay'] = math.max(
      value - ttfb - loadDelay - loadDuration,
      0.0,
    );
    _report(
      name: 'largest-contentful-paint',
      metric: 'LCP',
      id: _newId(),
      value: value,
      delta: value,
      entries: [entry],
      attribution: attribution,
    );
  }

  // ---- CLS ----------------------------------------------------------------

  void _onLayoutShift(List<JSObject> entries) {
    for (final e in entries) {
      if (jsBool(e, 'hadRecentInput') == true) continue;
      final sources = jsList(jsGet(e, 'sources'));
      final target =
          sources.isEmpty ? null : describeNode(jsGet(sources.first, 'node'));
      if (_cls.add(
        jsNum0(e, 'value'),
        jsNum0(e, 'startTime'),
        target: target,
      )) {
        _clsEntries.add(e);
      }
    }
  }

  void _reportCls() {
    final value = _cls.value;
    if (_clsReported != null && value <= _clsReported!) return;
    // web-vitals reports a CLS of 0 once the page is hidden.
    final delta = value - (_clsReported ?? 0);
    _clsReported = value;
    _report(
      name: 'layout-shift',
      metric: 'CLS',
      id: _clsId,
      value: value,
      delta: delta,
      entries: _clsEntries,
      attribution: {
        if (_cls.largestShiftTarget != null)
          'largestShiftTarget': _cls.largestShiftTarget!,
        if (_cls.largestShiftValue > 0) ...{
          'largestShiftTime': _cls.largestShiftTime,
          'largestShiftValue': _cls.largestShiftValue,
          'loadState': _loadState(_cls.largestShiftTime),
        },
      },
    );
  }

  // ---- INP ----------------------------------------------------------------

  void _onEvents(List<JSObject> entries) {
    for (final e in entries) {
      final id = jsNum(e, 'interactionId')?.toInt() ?? 0;
      if (id == 0) continue;
      _inp.add(
        InpInteraction(
          interactionId: id,
          duration: jsNum0(e, 'duration'),
          startTime: jsNum0(e, 'startTime'),
          processingStart: jsNum0(e, 'processingStart'),
          processingEnd: jsNum0(e, 'processingEnd'),
          name: jsStr(e, 'name') ?? '',
          target: describeNode(jsGet(e, 'target')),
        ),
      );
    }
  }

  void _reportInp() {
    final worst = _inp.worst;
    if (worst == null) return;
    final value = worst.duration;
    if (_inpReported != null && value <= _inpReported!) return;
    final delta = value - (_inpReported ?? 0);
    _inpReported = value;
    _report(
      name: 'interaction-next-paint',
      metric: 'INP',
      id: _inpId,
      value: value,
      delta: delta,
      entries: const [],
      attribution: {
        ...worst.attribution,
        'loadState': _loadState(worst.startTime),
      },
    );
  }

  // ---- reporting ----------------------------------------------------------

  void _report({
    required String name,
    required String metric,
    required String id,
    required double value,
    required double delta,
    required List<JSObject> entries,
    required Map<String, Object> attribution,
  }) {
    final attrs = <String, Object>{
      'web_vital.name': name,
      'web_vital.id': id,
      'web_vital.navigationType': _navigationType,
      'web_vital.delta': delta,
      'web_vital.rating': webVitalRating(metric, value),
      'web_vital.value': value,
      'web_vital.entries': safeJson(
        entries
            .map(
              (e) => {
                'name': jsStr(e, 'name'),
                'entryType': jsStr(e, 'entryType'),
                'startTime': jsNum(e, 'startTime'),
                'duration': jsNum(e, 'duration'),
              },
            )
            .toList(),
      ),
    };
    attribution.forEach((key, value) {
      attrs['web_vital.attribution.${toSnakeCase(key)}'] = value;
    });
    WebTelemetry.startSpan(
      name,
      scope: _scope,
      parent: _parent,
      attributes: attrs,
    ).end();
  }
}
