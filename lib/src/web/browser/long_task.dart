// Licensed under the Apache License, Version 2.0

import '../web_telemetry.dart';
import 'js_helpers.dart';

/// One span per main-thread task over 50ms, like the browser SDK's
/// long-task instrumentation (`longtask {pathname}`, `event.type=longtask`).
/// Includes tasks buffered before the SDK started, e.g. CanvasKit startup.
class LongTaskInstrumentation {
  Disposer? _stop;

  void enable() {
    final origin = timeOrigin;
    _stop = observePerformance('longtask', (entries) {
      for (final entry in entries) {
        final start = jsNum0(entry, 'startTime');
        final duration = jsNum0(entry, 'duration');
        final attrs = <String, Object>{
          'component': 'long-task',
          'event.type': 'longtask',
          'longtask.name': jsStr(entry, 'name') ?? 'unknown',
          'longtask.entry_type': jsStr(entry, 'entryType') ?? 'longtask',
          'longtask.duration': duration,
        };
        final attribution = jsList(jsGet(entry, 'attribution'));
        for (var i = 0; i < attribution.length; i++) {
          final a = attribution[i];
          final prefix =
              attribution.length > 1
                  ? 'longtask.attribution[$i]'
                  : 'longtask.attribution';
          final values = <String, Object?>{
            'name': jsStr(a, 'name'),
            'entry_type': jsStr(a, 'entryType'),
            'start_time': jsNum(a, 'startTime'),
            'duration': jsNum(a, 'duration'),
            'container_type': jsStr(a, 'containerType'),
            'container_src': jsStr(a, 'containerSrc'),
            'container_id': jsStr(a, 'containerId'),
            'container_name': jsStr(a, 'containerName'),
          };
          values.forEach((key, value) {
            if (value != null) attrs['$prefix.$key'] = value;
          });
        }
        final span = WebTelemetry.startSpan(
          'longtask $locationPathname',
          scope: '@opentelemetry/instrumentation-long-task',
          startTime: perfToDateTime(origin, start),
          attributes: attrs,
        );
        span.end(endTime: perfToDateTime(origin, start + duration));
      }
    });
  }

  void disable() {
    _stop?.call();
    _stop = null;
  }
}
