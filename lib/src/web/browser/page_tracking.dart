// Licensed under the Apache License, Version 2.0

import 'dart:async';
import 'dart:math' as math;

import '../../flutterrific_otel.dart';
import '../web_telemetry.dart';
import 'js_helpers.dart';

const _scope = '@middleware.io/page-tracking-instrumentation';

/// The page identity used for `root.url`. Flutter's default URL strategy puts
/// the route in the fragment (`/#/details`), where the pathname alone would
/// make every screen the same page, so a `#/` fragment is kept.
String currentPagePath() {
  final hash = jsStr(jsLocation, 'hash') ?? '';
  return hash.startsWith('#/')
      ? '$locationPathname$hash'
      : locationPathname;
}

/// Port of the browser SDK's page tracking: a `pageview` span whenever the
/// page path changes (history API, back/forward, hash routing), `pageleave`
/// when the tab is hidden and `pagehide` on unload. The current page is also
/// set as global attributes (`root.url`, `page.href`, `page.title`, referrer)
/// so every later span says which page it belongs to.
///
/// The DOM-driven parts of the browser SDK (form `change`/`submit`, document
/// scroll depth) have nothing to observe in a Flutter app, which renders to a
/// canvas and scrolls inside its own viewport.
class PageTrackingInstrumentation {
  final List<Disposer> _disposers = [];
  String _lastPath = '';
  String _lastHref = '';
  bool _leaveReported = false;

  void enable() {
    _lastHref = locationHref;
    _captureLocationChange('load');

    _disposers.add(
      patchMethod(jsObj(jsWindow, 'history'), 'pushState', (orig, self, args) {
        final result = reflectApply(orig, self, args);
        _onNavigate('pushstate');
        return result;
      }),
    );
    _disposers.add(
      patchMethod(jsObj(jsWindow, 'history'), 'replaceState', (
        orig,
        self,
        args,
      ) {
        final result = reflectApply(orig, self, args);
        _onNavigate('replacestate');
        return result;
      }),
    );
    _disposers.add(
      listen(jsWindow, 'popstate', (_) {
        Timer.run(() => _onNavigate('popstate'));
      }),
    );
    _disposers.add(
      listen(jsWindow, 'hashchange', (_) => _onNavigate('hashchange')),
    );
    _disposers.add(
      listen(jsDocument, 'visibilitychange', (_) {
        if (documentHidden) {
          _reportPageLeave('visibilitychange', _lastHref);
        } else {
          _leaveReported = false;
        }
      }),
    );
    _disposers.add(
      listen(jsWindow, 'pagehide', (_) => _reportPageEvent('pagehide')),
    );
  }

  void disable() {
    for (final d in _disposers.reversed) {
      d();
    }
    _disposers.clear();
  }

  void _onNavigate(String type) {
    final href = locationHref;
    if (href != _lastHref) {
      _reportPageLeave(type, _lastHref);
      _lastHref = href;
      _leaveReported = false;
    }
    _captureLocationChange(type);
  }

  void _captureLocationChange(String navigationType) {
    final path = currentPagePath();
    if (path == _lastPath) return;
    final referrer = jsStr(jsDocument, 'referrer') ?? '';
    String referrerDomain = 'direct';
    if (referrer.isNotEmpty) {
      referrerDomain = Uri.tryParse(referrer)?.host ?? 'direct';
    }
    FlutterOTel.setAttributes({
      'page.title': documentTitle,
      'root.url': path,
      'prev.root.url': _lastPath,
      'page.href': locationHref,
      'referrer': referrer.isEmpty ? 'direct' : referrer,
      'referrer.domain': referrerDomain,
    });
    // event.type stays "pageview" (the initial one is navigation.type=load);
    // "load" belongs to the documentLoad span.
    _reportPageEvent('pageview', {
      'prev.root.url': _lastPath,
      'navigation.type': navigationType,
    });
    _lastPath = path;
  }

  void _reportPageEvent(String name, [Map<String, Object> extra = const {}]) {
    WebTelemetry.startSpan(
      name,
      scope: _scope,
      attributes: {
        'page.title': documentTitle,
        'root.url': currentPagePath(),
        'event.type': name,
        'page.href': locationHref,
        ...extra,
      },
    ).end();
  }

  void _reportPageLeave(String eventType, String href) {
    if (_leaveReported) return;
    _leaveReported = true;
    final documentElement = jsObj(jsDocument, 'documentElement');
    final vh = math.max(
      jsNum0(documentElement, 'clientHeight'),
      jsNum0(jsWindow, 'innerHeight'),
    );
    final vw = math.max(
      jsNum0(documentElement, 'clientWidth'),
      jsNum0(jsWindow, 'innerWidth'),
    );
    final scrollHeight = jsNum0(jsObj(jsDocument, 'body'), 'scrollHeight');
    WebTelemetry.startSpan(
      'pageleave',
      scope: _scope,
      attributes: {
        'event.type': eventType,
        'page.href': href,
        // A Flutter page never scrolls the document: it's all "above the
        // fold", which is what these report.
        'pageleave.max_scroll_view_depth': vh,
        'pageleave.max_scroll_percentage': 100,
        'pageleave.fold_line_percentage': 100,
        'pageleave.scroll_height': scrollHeight,
        'pageleave.viewport_height': vh,
        'pageleave.viewport_width': vw,
      },
    ).end();
  }
}
