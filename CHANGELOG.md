# Changelog

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
