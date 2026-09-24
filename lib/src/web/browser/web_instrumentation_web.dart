// Licensed under the Apache License, Version 2.0

// Flutter web: wires up the browser instrumentations.

import '../../flutterrific_otel.dart';
import '../web_instrumentation_options.dart';
import '../web_utils.dart';
import 'document_load.dart';
import 'errors_console.dart';
import 'js_helpers.dart';
import 'long_task.dart';
import 'network.dart';
import 'page_tracking.dart';
import 'web_vitals.dart';
import 'websocket.dart';

bool isBotTraffic() => isBotUserAgent(userAgent);

/// Browser identity on the resource, with the browser SDK's keys.
Map<String, Object> browserResourceAttributes() {
  final ua = userAgent;
  final info = browserInfo(ua);
  final os = browserOs(jsStr(jsNavigator, 'platform') ?? '', ua);
  return {
    'browser.name': info.name,
    'browser.version': info.version,
    'navigator.userAgent': ua,
    'origin': locationOrigin,
    'rum_origin': locationOrigin,
    if (os != null) 'os.name': os,
  };
}

final List<void Function()> _active = [];

void enable(
  WebInstrumentationOptions options, {
  required List<Pattern> ignoreUrls,
  required bool captureConsoleLog,
}) {
  disable();
  if (!options.enabled) return;

  // Each instrumentation starts independently: one failing (an API missing in
  // this browser) must not take the others down.
  void start(bool on, void Function() enableFn, void Function() disableFn) {
    if (!on) return;
    try {
      enableFn();
      _active.add(disableFn);
    } catch (_) {
      try {
        disableFn();
      } catch (_) {}
    }
  }

  // Errors first, so failures in the other instrumentations are captured.
  final errors = ErrorsConsoleInstrumentation(
    options: options,
    captureConsoleLog: captureConsoleLog,
  );
  start(options.errors || options.console, errors.enable, errors.disable);

  final network = NetworkInstrumentation(
    options: options,
    ignoreUrls: ignoreUrls,
  );
  start(options.network, network.enable, network.disable);

  final documentLoad = DocumentLoadInstrumentation(ignoreUrls: ignoreUrls);
  start(options.documentLoad, documentLoad.enable, documentLoad.disable);

  final pages = PageTrackingInstrumentation();
  start(options.pageTracking, pages.enable, pages.disable);

  final vitals = WebVitalsInstrumentation();
  start(options.webVitals, vitals.enable, vitals.disable);

  final longTasks = LongTaskInstrumentation();
  start(options.longTask, longTasks.enable, longTasks.disable);

  final websocket = WebSocketInstrumentation(ignoreUrls: ignoreUrls);
  start(options.websocket, websocket.enable, websocket.disable);

  // Any input while the tab is visible keeps the RUM session alive (the
  // browser SDK's markActivity), even without automatic interaction capture.
  for (final type in const [
    'click',
    'scroll',
    'mousedown',
    'keydown',
    'touchend',
    'visibilitychange',
  ]) {
    _active.add(
      listen(jsDocument, type, (_) {
        if (!documentHidden) FlutterOTel.notifyUserSessionActivity();
      }, capture: true),
    );
  }
}

void disable() {
  for (final d in _active.reversed) {
    try {
      d();
    } catch (_) {}
  }
  _active.clear();
}
