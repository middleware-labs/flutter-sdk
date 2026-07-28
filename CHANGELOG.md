# Changelog

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
