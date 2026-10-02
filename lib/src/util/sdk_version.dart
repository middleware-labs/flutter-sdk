// Licensed under the Apache License, Version 2.0

/// This package's version, reported as `mw.rum.sdk.version` on Dart telemetry
/// and passed to the native Android/iOS SDKs so their spans carry it too.
///
/// Dart can't read its own pubspec at runtime, so keep this equal to the
/// `version:` in pubspec.yaml (test/sdk_version_test.dart checks it).
const String middlewareFlutterSdkVersion = '2.1.2';
