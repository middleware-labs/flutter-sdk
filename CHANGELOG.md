# Changelog

## Unreleased

- Flutter web browser instrumentation, matching the Middleware browser SDK:
  document load and resource timings, `fetch` / `XMLHttpRequest` spans with
  trace-header propagation, Core Web Vitals (LCP, FCP, CLS, INP, TTFB), long
  tasks, page views / page leave, JS errors and console capture, WebSocket
  spans, rage clicks, tap-to-request attribution, and bot-traffic blocking.
  Configure with `FlutterOTel.initialize(webInstrumentation: ...)`; on by
  default on the web, no effect on other platforms.
- Everything is on by default, so `initialize` with an endpoint and account
  key is the whole setup:
  - `autoCaptureErrors` now defaults to `true`. `reportError` records an error
    object once even when both the SDK handler and an app handler (chained)
    report it.
  - `enableAutomaticUserInteractions` now defaults to `true`.
  - `WebInstrumentationOptions.websocket` now defaults to `true`.
  - The Dart session recorder (web, desktop) starts by itself after the first
    frame, and captures the whole root view when the app has no
    `RepaintBoundary(key: FlutterOTel.repaintBoundaryKey)`. Calling
    `startSessionRecording()` or wrapping the app is no longer needed;
    `stopSessionRecording()` before the first frame keeps it off.
- `enableMetrics` now defaults to `false`: the Flutter metrics exporter,
  reader and collectors are only created when you opt in.
- Session replay on web and desktop uses the native SDKs' standard quality:
  JPEG quality 50 (was 10), a 640 px short edge (was 320) captured at up to
  the device pixel ratio instead of 1x logical pixels, one frame a second
  (was two). Replays were visibly blurry.
- On the web the `os` resource attribute is the real OS (`Mac OS`,
  `Windows`, ...), as the browser SDK reports it, instead of `web`.
- Fixed a feedback loop on the web: Dart `print` / `debugPrint` writes to
  `console.log`, so console capture recorded the SDK's own diagnostics (e.g.
  `OTelLog.spanLogFunction = debugPrint` dumping every exported span) as new
  spans and logs, which the next export printed again, continuously. Dart
  output now goes to the original `console.log` through the `dartPrint` hook
  every web compiler honours, so only JavaScript console calls are captured.
- Performance:
  - Tap handling no longer walks the whole widget tree on every pointer down
    and up (quadratic in release builds). Targets are found with a pruned
    lookup along the path under the pointer, and swipe detection runs only
    when a pan actually happens.
  - Tapped controls are matched by type, so detection and `target_element`
    work in release web builds, where class names are minified.
  - The Dart recorder skips capture, GPU readback and JPEG encoding when
    Flutter rendered no frame since the last capture.
  - Per-frame recorder diagnostics print only with `OTelLog` debug logging.
  - `flutter run` debug artifacts (`*.dart.lib.js`, `dart_sdk.js`, dwds) are
    not reported as resources.
- Fixed `UISpan.end` ignoring `endTime` and `spanStatus`: spans ended with an
  explicit end time (`recordUserInteraction` with a `responseTime`,
  `recordPerformanceMetric`, navigation durations) were recorded as ending
  when `end` was called.
- Fixed `UITracer.createSpan` throwing a cast error.
- `UITracer.recordUserInteraction` now returns the recorded span.

## 2.1.0

- Fixed web session replay: web sessions had no playable recording. The Dart
  recorder (web and desktop) still uploaded JPEG tarballs to `/v1/rum`, which
  the backend turns into a video event that the Middleware session player
  ignores. It now emits the same rrweb stream as the native SDKs and the
  browser SDK (`rum_event` metrics to `/v1/metrics`): a full snapshot per
  session / viewport size / return to foreground, an image mutation per
  changed frame (identical frames are skipped), taps, and route names on the
  replay timeline.
- Deprecated `RecordingOptions.archiveChunkSize`, `staleArchiveMaxAge`,
  `staleScreenshotMaxAge` and `uploadStaleFilesOnStart`; they have no effect.
- Removed the unused `archive` and `path_provider` dependencies.

## 2.0.2

- Fixed Android session replay: Android sessions recorded nothing. Two causes:
  - Flutter draws its UI into a `SurfaceView`, which the native recorder
    neither captured nor noticed changing, so it gave up after the first
    frame. Fixed in the native SDK; bumped to
    `io.github.middleware-labs:android-sdk:3.1.6`.
  - The native SDK was initialized with the `Application` context after
    `FlutterActivity` had already resumed, so the recorder had no activity to
    capture until the app was backgrounded and reopened. The plugin is now
    `ActivityAware` and initializes the native SDK with the attached activity.
- No more extra one-span "Anonymous" session per app launch on Android (the
  native SDK's `record init` sampling probe, fixed in android-sdk 3.1.6).

## 2.0.1

- Bumped the native SDKs to `io.github.middleware-labs:android-sdk:3.1.5` and
  `MiddlewareRum` >= 2.2.4.

## 2.0.0

- **Breaking:** removed the `disableSessionRecordingV3` option from
  `FlutterOTel.initialize`. On Android/iOS the native recorder is now the only
  recorder; the Dart screenshot recorder is used on web only.
- Removed the `recordingV3` resource attribute. The backend no longer reads
  it; `recording` still signals that a session has a replay.

## 1.2.0

- `FlutterOTel.startSessionRecording()` / `stopSessionRecording()` now work on
  the **native v3** path (Android/iOS), where they were previously no-ops — they
  only drove the Dart recorder used for web and the v3 opt-out.
- Added `FlutterOTel.isSessionRecording()`.
- Recording control is sticky: it survives session rotation and sampler
  re-evaluation, and `startSessionRecording()` overrides both
  `enableSessionRecording: false` and the sampler, so a session can be recorded
  on demand for a single flow.
- The `recording` / `recordingV3` resource attributes now follow the live
  recording state instead of being frozen at init.
- Fixed `UIMeterProvider.resource` being a no-op setter, which stranded metrics
  on the init-time `session.id` and recording attributes across session
  rotations.
- Removed the unused public `FlutterOTel.isRecording` field (it was always
  `false` and never updated); use `isSessionRecording()`.
- Bumped native SDKs to `MiddlewareRum ~> 2.2` and
  `io.github.middleware-labs:android-sdk:3.1.0`, which add the underlying
  start/stop recording APIs.

## 1.1.1

- Converted the package from a pure-Dart package to a Flutter plugin with
  native Android (`io.github.middleware-labs:android-sdk`) and iOS
  (`MiddlewareRum`) bridges.
- Session recording v3: rrweb-based native recording (`recordingV3` resource
  attribute) replaces the Dart screenshot recorder on Android/iOS; the Dart
  recorder is still used on web or when `disableSessionRecordingV3` is set.
- Native session linking: the Dart-owned session id (and rotations) now drive
  native crash reports, ANR detection, and session replay; screen names from
  the navigator observer flow into native telemetry and the replay timeline.
- Session policy: inactivity timeout is now 15 minutes (was 5); maximum
  session duration remains 4 hours — aligned across all Middleware RUM SDKs.
- New `FlutterOTel.initialize` options: `deploymentEnvironment`,
  `enableSessionRecording`, `disableSessionRecordingV3`,
  `sessionSamplingRatio`, `autoCaptureErrors`, and native `RecordingOptions`
  (frequency, quality, `maskAllTextInputs`, `maskAllImages`).
- Fixed session rotation not updating the OTLP resource: spans, logs, and
  metrics emitted after a rotation now carry the new `session.id`.
- Fixed the navigator observer reporting a stale route after GoRouter `go()`
  navigations (the removed route overwrote the pushed one), and navigation
  events now report the correct `fromRoute`.
- Fixed logs export on mobile by switching from the gRPC exporter (which
  dialed the wrong port for https endpoints) to OTLP-HTTP.
- Resource attribute parity with the native SDKs: `recordingV3`, `os`
  reported as `Android`/`iOS`, plus native-provided app version, OS version,
  and device model.

## 1.0.16

- Previous pub.dev release (pure-Dart package).
