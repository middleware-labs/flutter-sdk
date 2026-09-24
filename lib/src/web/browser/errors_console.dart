// Licensed under the Apache License, Version 2.0

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

import '../web_instrumentation_options.dart';
import '../web_telemetry.dart';
import '../web_utils.dart';
import 'js_helpers.dart';

/// Browser-level errors and console output, as the browser SDK's logs
/// instrumentation reports them:
///
/// - `error` events → `error.type=uncaughtException`
/// - `unhandledrejection` → `unhandledRejection`
/// - failed `<img>`/`<script>`/`<link>` loads → `documentError`
/// - `console.error` → `consoleError`
///
/// each as an `error-trace` span (status ERROR, `exception` event with the
/// parsed JS stack for sourcemaps) plus an ERROR log record; and
/// `console.log/info/warn/debug` as a log record plus an `event.type=info|warn|
/// debug` span, rate limited to [WebInstrumentationOptions.consoleRateLimit]
/// per second.
///
/// Dart errors caught by Flutter (`FlutterError.onError`,
/// `PlatformDispatcher.onError`) are covered by `autoCaptureErrors`; this adds
/// what never reaches Dart: JS libraries, interop and resource failures.
///
/// Dart's own `print` / `debugPrint` output is deliberately *not* captured:
/// it includes the SDK's diagnostics (e.g. `OTelLog.spanLogFunction` dumping
/// every exported span), and capturing that turns each export into new spans
/// that the next export prints again, forever. See [_routeDartPrint].
class ErrorsConsoleInstrumentation {
  ErrorsConsoleInstrumentation({required this.options});

  final WebInstrumentationOptions options;

  final List<Disposer> _disposers = [];

  /// Set while the SDK itself is reporting, so anything it prints is not
  /// captured again.
  bool _reporting = false;

  int _windowStart = 0;
  int _windowCount = 0;
  int _dropped = 0;

  void enable() {
    // Before console.log is patched, so it binds the original.
    if (options.console) _routeDartPrint();
    if (options.errors) {
      _disposers.add(listen(jsWindow, 'error', _onErrorEvent));
      _disposers.add(listen(jsWindow, 'unhandledrejection', _onRejection));
      _disposers.add(
        listen(
          jsObj(jsDocument, 'documentElement'),
          'error',
          _onResourceError,
          capture: true,
        ),
      );
      _wrapConsole('error', null);
    }
    if (options.console) {
      _wrapConsole('log', Severity.INFO);
      _wrapConsole('info', Severity.INFO);
      _wrapConsole('warn', Severity.WARN);
      _wrapConsole('debug', Severity.DEBUG);
    }
  }

  /// Every web compiler (dart2js, DDC, dart2wasm) sends `print` to
  /// `globalThis.dartPrint` when it is a function, and to `console.log`
  /// otherwise. Pointing it at the original, unpatched `console.log` keeps
  /// Dart output printing exactly as before while bypassing the capture
  /// entirely: no feedback loop, and no per-print cost. (Dart prints are
  /// captured as logs on every platform with `logPrint` instead.)
  void _routeDartPrint() {
    if (jsGet(jsWindow, 'dartPrint') != null) return; // the page routes it
    final console = jsObj(jsWindow, 'console');
    final log = jsGet(console, 'log');
    if (console == null || log == null || !log.isA<JSFunction>()) return;
    final original = (log as JSFunction).callMethod<JSAny?>(
      'bind'.toJS,
      console,
    );
    jsWindow.setProperty('dartPrint'.toJS, original);
    _disposers.add(() {
      try {
        jsWindow.delete('dartPrint'.toJS);
      } catch (_) {}
    });
  }

  void disable() {
    for (final d in _disposers.reversed) {
      d();
    }
    _disposers.clear();
  }

  void _guard(void Function() body) {
    if (_reporting) return;
    _reporting = true;
    try {
      body();
    } catch (_) {
      // never let reporting break the page
    } finally {
      _reporting = false;
    }
  }

  // ---- errors -------------------------------------------------------------

  void _onErrorEvent(JSObject event) {
    // Resource errors don't reach window listeners; this is a script error.
    final error = jsGet(event, 'error');
    final message = jsStr(event, 'message');
    if (shouldIgnoreMessage(message ?? jsStr(event, 'filename'))) return;
    _guard(() {
      if (error != null && error.isA<JSObject>()) {
        _reportError('uncaughtException', error);
      } else if (isUsefulMessage(message)) {
        WebTelemetry.recordBrowserError(
          errorType: 'uncaughtException',
          message: message!,
          object: 'String',
        );
      }
    });
  }

  void _onRejection(JSObject event) {
    final reason = jsGet(event, 'reason');
    if (reason == null) return;
    final text =
        reason.isA<JSObject>()
            ? (jsStr(reason as JSObject, 'message') ?? jsToString(reason))
            : jsToString(reason);
    if (shouldIgnoreMessage(text)) return;
    _guard(() => _reportError('unhandledRejection', reason));
  }

  void _onResourceError(JSObject event) {
    final target = jsObj(event, 'target');
    final tag = jsStr(target, 'tagName');
    if (target == null || tag == null) return;
    final src =
        jsStr(target, 'src') ??
        jsStr(target, 'href') ??
        jsStr(jsObj(target, 'href'), 'baseVal');
    if (shouldIgnoreMessage(src)) return;
    _guard(() {
      WebTelemetry.recordBrowserError(
        errorType: 'documentError',
        message: '${jsStr(event, 'type') ?? 'error'} on $tag',
        extraAttributes: {
          'target_element': tag,
          'target_xpath': describeNode(target),
          if (src != null && src.isNotEmpty) 'target_src': src,
        },
      );
    });
  }

  /// Reports a thrown JS value: an Error keeps its name/stack, anything else
  /// is stringified.
  void _reportError(String errorType, JSAny? value) {
    if (value != null && value.isA<JSObject>()) {
      final o = value as JSObject;
      final stack = jsStr(o, 'stack');
      final message = jsStr(o, 'message');
      if (message != null || stack != null) {
        final name = jsStr(o, 'name');
        if (!isUsefulMessage(message) && stack == null) return;
        WebTelemetry.recordBrowserError(
          errorType: errorType,
          message: message ?? jsToString(o),
          name: name,
          stack: stack,
          object: name ?? jsStr(jsObj(o, 'constructor'), 'name') ?? 'Error',
        );
        return;
      }
    }
    final text = jsToString(value);
    if (!isUsefulMessage(text)) return;
    WebTelemetry.recordBrowserError(
      errorType: errorType,
      message: text,
      object: 'String',
    );
  }

  // ---- console ------------------------------------------------------------

  /// [severity] null means `console.error`, reported as an error.
  void _wrapConsole(String method, Severity? severity) {
    _disposers.add(
      patchMethod(jsObj(jsWindow, 'console'), method, (orig, self, args) {
        if (!_reporting) {
          final list = jsArgs(args);
          _guard(() {
            if (severity == null) {
              _onConsoleError(list);
            } else {
              _onConsole(method, severity, list);
            }
          });
        }
        return reflectApply(orig, self, args);
      }),
    );
  }

  void _onConsoleError(List<JSAny?> args) {
    if (args.isEmpty) return;
    final text = _formatArgs(args);
    if (shouldIgnoreMessage(text)) return;
    if (args.length == 1) {
      _reportError('consoleError', args.first);
      return;
    }
    // Several arguments: one message, but keep the first Error's stack.
    JSObject? firstError;
    for (final a in args) {
      if (a != null && jsInstanceOf(a, 'Error')) {
        firstError = a as JSObject;
        break;
      }
    }
    if (!isUsefulMessage(text)) return;
    final name = jsStr(firstError, 'name');
    WebTelemetry.recordBrowserError(
      errorType: 'consoleError',
      message: text,
      name: name,
      stack: jsStr(firstError, 'stack'),
      object: name ?? 'String',
    );
  }

  void _onConsole(String method, Severity severity, List<JSAny?> args) {
    final text = _formatArgs(args);
    if (text.isEmpty || shouldIgnoreMessage(text) || !_allowConsoleRecord()) {
      return;
    }
    final type = method == 'log' ? 'info' : method;
    _recordConsole(type, severity, limitLen(text, messageLimit));
  }

  void _recordConsole(String type, Severity severity, String message) {
    final span = WebTelemetry.startSpan(
      message,
      scope: 'error-trace',
      attributes: {'type': type, 'event.type': type},
    );
    span.end();
    WebTelemetry.log(
      loggerName: 'browser.console',
      severity: severity,
      body: message,
      attributes: {'type': type},
      span: span,
    );
  }

  /// A chatty logger would otherwise turn every frame into a log record, a
  /// span and an export flush; drops are reported rather than silent.
  bool _allowConsoleRecord() {
    final limit = options.consoleRateLimit;
    if (limit <= 0) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _windowStart >= 1000) {
      final dropped = _dropped;
      _windowStart = now;
      _windowCount = 0;
      _dropped = 0;
      if (dropped > 0) {
        _recordConsole(
          'warn',
          Severity.WARN,
          '[Middleware] dropped $dropped console messages (rate limit $limit/s)',
        );
      }
    }
    if (_windowCount >= limit) {
      _dropped++;
      return false;
    }
    _windowCount++;
    return true;
  }

  /// Joins console arguments the way they print, within a bounded budget
  /// (serialising a large object graph first and truncating after can hang
  /// the page).
  String _formatArgs(List<JSAny?> args) {
    final budgetTotal = messageLimit * 2;
    final parts = <String>[];
    var budget = budgetTotal;
    for (final a in args) {
      if (budget <= 0) break;
      String s;
      if (a != null && a.isA<JSString>()) {
        s = (a as JSString).toDart;
      } else if (a != null && jsInstanceOf(a, 'Error')) {
        final o = a as JSObject;
        s = '${jsStr(o, 'name') ?? 'Error'}: ${jsStr(o, 'message') ?? ''}';
      } else if (a != null && a.isA<JSObject>() && !a.isA<JSFunction>()) {
        s = _boundedStringify(a as JSObject, budget);
      } else {
        s = jsToString(a);
      }
      if (s.length > budget) s = s.substring(0, budget);
      parts.add(s);
      budget -= s.length;
    }
    return parts.join(' ');
  }

  /// JSON-ish rendering of a logged object with a character budget, a depth
  /// cap and a global visited set, so cost stays bounded for object graphs
  /// with back-references (where JSON.stringify can hang or throw).
  String _boundedStringify(JSObject root, int budget) {
    final JSObject seen;
    try {
      seen =
          (globalContext['WeakSet'] as JSFunction)
              .callAsConstructor<JSObject>();
    } catch (_) {
      return jsToString(root);
    }
    final objectCtor = globalContext['Object'] as JSObject;
    final arrayCtor = globalContext['Array'] as JSObject;
    final buf = StringBuffer();
    var remaining = budget;

    void write(String s) {
      if (remaining <= 0) return;
      final t = s.length > remaining ? s.substring(0, remaining) : s;
      buf.write(t);
      remaining -= t.length;
    }

    void walk(JSAny? v, int depth) {
      if (remaining <= 0) return;
      if (v == null) return write('null');
      if (v.isA<JSString>()) return write(jsonEncode((v as JSString).toDart));
      if (v.isA<JSNumber>() || v.isA<JSBoolean>()) return write(jsToString(v));
      if (!v.isA<JSObject>() || v.isA<JSFunction>()) {
        return write(jsonEncode(jsToString(v)));
      }
      final o = v as JSObject;
      if (seen.callMethod<JSBoolean>('has'.toJS, o).toDart) {
        return write('"[Circular]"');
      }
      seen.callMethod<JSAny?>('add'.toJS, o);
      if (depth >= 4) return write('"[Object]"');
      final isArray = arrayCtor.callMethod<JSBoolean>('isArray'.toJS, o).toDart;
      final keys =
          objectCtor.callMethod<JSArray<JSString>>('keys'.toJS, o).toDart;
      write(isArray ? '[' : '{');
      var first = true;
      for (final key in keys) {
        if (remaining <= 0) break;
        if (!first) write(',');
        first = false;
        if (!isArray) write('${jsonEncode(key.toDart)}:');
        JSAny? child;
        try {
          child = o.getProperty<JSAny?>(key);
        } catch (_) {
          child = '[Thrown]'.toJS;
        }
        walk(child, depth + 1);
      }
      write(isArray ? ']' : '}');
    }

    try {
      walk(root, 0);
    } catch (_) {
      return jsToString(root);
    }
    return buf.toString();
  }
}
