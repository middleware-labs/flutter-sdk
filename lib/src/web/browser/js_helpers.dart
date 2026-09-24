// Licensed under the Apache License, Version 2.0

// Thin, defensive accessors over raw browser objects. Performance entries and
// events are read by property name rather than through package:web types so
// fields newer than the bindings (responseStatus, attribution, interactionId,
// ...) work and a missing field reads as null instead of throwing.

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../web_utils.dart';

JSObject get jsWindow => globalContext;

JSAny? jsGet(JSObject? o, String key) {
  if (o == null) return null;
  try {
    return o.getProperty<JSAny?>(key.toJS);
  } catch (_) {
    return null;
  }
}

double? jsNum(JSObject? o, String key) {
  final v = jsGet(o, key);
  if (v != null && v.isA<JSNumber>()) {
    final d = (v as JSNumber).toDartDouble;
    return d.isFinite ? d : null;
  }
  return null;
}

double jsNum0(JSObject? o, String key) => jsNum(o, key) ?? 0;

String? jsStr(JSObject? o, String key) {
  final v = jsGet(o, key);
  if (v != null && v.isA<JSString>()) return (v as JSString).toDart;
  return null;
}

bool? jsBool(JSObject? o, String key) {
  final v = jsGet(o, key);
  if (v != null && v.isA<JSBoolean>()) return (v as JSBoolean).toDart;
  return null;
}

JSObject? jsObj(JSObject? o, String key) {
  final v = jsGet(o, key);
  if (v != null && v.isA<JSObject>()) return v as JSObject;
  return null;
}

/// Elements of a JS array-like (`length` + index access).
List<JSObject> jsList(JSAny? arrayLike) {
  if (arrayLike == null || !arrayLike.isA<JSObject>()) return const [];
  final o = arrayLike as JSObject;
  final length = jsNum(o, 'length')?.toInt() ?? 0;
  final out = <JSObject>[];
  for (var i = 0; i < length; i++) {
    final item = o.getProperty<JSAny?>(i.toJS);
    if (item != null && item.isA<JSObject>()) out.add(item as JSObject);
  }
  return out;
}

/// `String(value)` for any JS value.
String jsToString(JSAny? value) {
  if (value == null) return 'undefined';
  try {
    final s = globalContext.callMethod<JSString>('String'.toJS, value);
    return s.toDart;
  } catch (_) {
    return '[unprintable]';
  }
}

bool jsInstanceOf(JSAny? value, String constructorName) {
  if (value == null) return false;
  final ctor = globalContext.getProperty<JSAny?>(constructorName.toJS);
  if (ctor == null || !ctor.isA<JSFunction>()) return false;
  return value.instanceof(ctor as JSFunction);
}

JSObject? get jsPerformance => jsObj(globalContext, 'performance');
JSObject? get jsDocument => jsObj(globalContext, 'document');
JSObject? get jsLocation => jsObj(globalContext, 'location');
JSObject? get jsNavigator => jsObj(globalContext, 'navigator');

/// `performance.timeOrigin` (falls back to navigationStart, then now - now).
double get timeOrigin {
  final perf = jsPerformance;
  final origin = jsNum(perf, 'timeOrigin');
  if (origin != null && origin > 0) return origin;
  final navStart = jsNum(jsObj(perf, 'timing'), 'navigationStart');
  if (navStart != null && navStart > 0) return navStart;
  return DateTime.now().millisecondsSinceEpoch - perfNow();
}

double perfNow() {
  try {
    return jsPerformance!.callMethod<JSNumber>('now'.toJS).toDartDouble;
  } catch (_) {
    return 0;
  }
}

String get locationHref => jsStr(jsLocation, 'href') ?? '';
String get locationPathname => jsStr(jsLocation, 'pathname') ?? '';
String get locationOrigin => jsStr(jsLocation, 'origin') ?? '';
String get locationHostname => jsStr(jsLocation, 'hostname') ?? '';
String get documentTitle => jsStr(jsDocument, 'title') ?? '';
String get userAgent => jsStr(jsNavigator, 'userAgent') ?? '';
bool get documentHidden => jsStr(jsDocument, 'visibilityState') == 'hidden';

List<JSObject> performanceEntriesByType(String type) {
  try {
    return jsList(
      jsPerformance?.callMethod<JSAny?>('getEntriesByType'.toJS, type.toJS),
    );
  } catch (_) {
    return const [];
  }
}

/// A PerformanceResourceTiming / PerformanceNavigationTiming entry as data.
ResourceTimingData resourceTimingOf(JSObject e) => ResourceTimingData(
  name: jsStr(e, 'name') ?? '',
  initiatorType: jsStr(e, 'initiatorType') ?? '',
  startTime: jsNum0(e, 'startTime'),
  duration: jsNum0(e, 'duration'),
  workerStart: jsNum0(e, 'workerStart'),
  redirectStart: jsNum0(e, 'redirectStart'),
  redirectEnd: jsNum0(e, 'redirectEnd'),
  fetchStart: jsNum0(e, 'fetchStart'),
  domainLookupStart: jsNum0(e, 'domainLookupStart'),
  domainLookupEnd: jsNum0(e, 'domainLookupEnd'),
  connectStart: jsNum0(e, 'connectStart'),
  secureConnectionStart: jsNum0(e, 'secureConnectionStart'),
  connectEnd: jsNum0(e, 'connectEnd'),
  requestStart: jsNum0(e, 'requestStart'),
  responseStart: jsNum0(e, 'responseStart'),
  responseEnd: jsNum0(e, 'responseEnd'),
  transferSize: jsNum0(e, 'transferSize'),
  encodedBodySize: jsNum0(e, 'encodedBodySize'),
  decodedBodySize: jsNum0(e, 'decodedBodySize'),
  responseStatus: jsNum0(e, 'responseStatus').toInt(),
  nextHopProtocol: jsStr(e, 'nextHopProtocol') ?? '',
);

typedef Disposer = void Function();

/// `target.addEventListener(type, fn, {capture, passive})`; returns a
/// function that removes the listener again.
Disposer listen(
  JSObject? target,
  String type,
  void Function(JSObject event) fn, {
  bool capture = false,
  bool passive = true,
}) {
  if (target == null) return () {};
  final handler =
      ((JSObject event) {
        try {
          fn(event);
        } catch (_) {
          // instrumentation must never break the page
        }
      }).toJS;
  final options =
      JSObject()
        ..setProperty('capture'.toJS, capture.toJS)
        ..setProperty('passive'.toJS, passive.toJS);
  try {
    target.callMethod<JSAny?>(
      'addEventListener'.toJS,
      type.toJS,
      handler,
      options,
    );
  } catch (_) {
    return () {};
  }
  return () {
    try {
      target.callMethod<JSAny?>(
        'removeEventListener'.toJS,
        type.toJS,
        handler,
        options,
      );
    } catch (_) {}
  };
}

bool supportsEntryType(String type) {
  final po = jsObj(globalContext, 'PerformanceObserver');
  final raw = jsGet(po, 'supportedEntryTypes');
  if (raw == null || !raw.isA<JSObject>()) return false;
  final list = raw as JSObject;
  final length = jsNum(list, 'length')?.toInt() ?? 0;
  for (var i = 0; i < length; i++) {
    final v = list.getProperty<JSAny?>(i.toJS);
    if (v != null && v.isA<JSString>() && (v as JSString).toDart == type) {
      return true;
    }
  }
  return false;
}

/// Observes performance entries of [type]; returns a disconnect function.
Disposer observePerformance(
  String type,
  void Function(List<JSObject> entries) onEntries, {
  bool buffered = true,
  int? durationThreshold,
}) {
  final ctor = globalContext.getProperty<JSAny?>('PerformanceObserver'.toJS);
  if (ctor == null || !ctor.isA<JSFunction>() || !supportsEntryType(type)) {
    return () {};
  }
  try {
    final callback =
        ((JSObject list, JSAny? _) {
          try {
            onEntries(jsList(list.callMethod<JSAny?>('getEntries'.toJS)));
          } catch (_) {}
        }).toJS;
    final observer = (ctor as JSFunction).callAsConstructor<JSObject>(callback);
    final init =
        JSObject()
          ..setProperty('type'.toJS, type.toJS)
          ..setProperty('buffered'.toJS, buffered.toJS);
    if (durationThreshold != null) {
      init.setProperty('durationThreshold'.toJS, durationThreshold.toJS);
    }
    observer.callMethod<JSAny?>('observe'.toJS, init);
    return () {
      try {
        observer.callMethod<JSAny?>('disconnect'.toJS);
      } catch (_) {}
    };
  } catch (_) {
    return () {};
  }
}

/// A short human label for a DOM node (`tag#id.class`), used where the
/// browser SDK reports an element (web-vitals targets, error targets).
String? describeNode(JSAny? node) {
  if (node == null || !node.isA<JSObject>()) return null;
  final o = node as JSObject;
  final tag = jsStr(o, 'tagName')?.toLowerCase() ?? jsStr(o, 'nodeName');
  if (tag == null) return null;
  final id = jsStr(o, 'id');
  final cls = jsStr(o, 'className');
  final buf = StringBuffer(tag);
  if (id != null && id.isNotEmpty) buf.write('#$id');
  if (cls != null && cls.trim().isNotEmpty) {
    buf.write('.${cls.trim().split(RegExp(r'\s+')).join('.')}');
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------
// Patching through Proxy
//
// A Dart function converted with `toJS` has a fixed arity, so it can neither
// see nor forward a variable argument list (`console.log(...args)`,
// `xhr.open(m, u)` vs `xhr.open(m, u, async)` — an explicit `undefined` async
// makes the request synchronous). A Proxy trap receives the real argument
// array and needs no eval, so it also works under a strict CSP.
// ---------------------------------------------------------------------------

// callMethodVarArgs, not callMethod: dart2js' callMethod drops every argument
// from the first null on, so `Reflect.apply(fn, undefined, args)` (a plain
// `fetch(url)` call has no `this`) would lose its argument list.
JSAny? reflectApply(JSAny target, JSAny? thisArg, JSArray<JSAny?> args) =>
    (globalContext['Reflect'] as JSObject).callMethodVarArgs<JSAny?>(
      'apply'.toJS,
      [target, thisArg, args],
    );

JSObject reflectConstruct(
  JSAny target,
  JSArray<JSAny?> args,
  JSAny? newTarget,
) => (globalContext['Reflect'] as JSObject).callMethodVarArgs<JSObject>(
  'construct'.toJS,
  [target, args, newTarget ?? target],
);

List<JSAny?> jsArgs(JSArray<JSAny?> args) => args.toDart;

/// A callable proxy of [target] whose calls go through [trap].
JSObject proxyApply(
  JSFunction target,
  JSAny? Function(JSFunction target, JSAny? thisArg, JSArray<JSAny?> args) trap,
) {
  final handler =
      JSObject()..setProperty(
        'apply'.toJS,
        ((JSFunction t, JSAny? thisArg, JSArray<JSAny?> args) =>
                trap(t, thisArg, args))
            .toJS,
      );
  return (globalContext['Proxy'] as JSFunction).callAsConstructor<JSObject>(
    target,
    handler,
  );
}

/// A constructible proxy of [target] whose `new` goes through [trap].
JSObject proxyConstruct(
  JSFunction target,
  JSObject Function(JSFunction target, JSArray<JSAny?> args, JSAny? newTarget)
  trap,
) {
  final handler =
      JSObject()..setProperty(
        'construct'.toJS,
        ((JSFunction t, JSArray<JSAny?> args, JSAny? newTarget) =>
                trap(t, args, newTarget))
            .toJS,
      );
  return (globalContext['Proxy'] as JSFunction).callAsConstructor<JSObject>(
    target,
    handler,
  );
}

/// Replaces `owner[method]` with an apply-proxy; returns a restore function.
Disposer patchMethod(
  JSObject? owner,
  String method,
  JSAny? Function(JSFunction original, JSAny? thisArg, JSArray<JSAny?> args)
  trap,
) {
  final original = jsGet(owner, method);
  if (owner == null || original == null || !original.isA<JSFunction>()) {
    return () {};
  }
  final fn = original as JSFunction;
  owner.setProperty(method.toJS, proxyApply(fn, trap));
  return () {
    try {
      owner.setProperty(method.toJS, fn);
    } catch (_) {}
  };
}
