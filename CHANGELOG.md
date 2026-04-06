## 0.4.0 2026/04/05

* **Log Signal support**: Added OpenTelemetry Log Signal integration for Flutter
  * UILogger — Flutter-specific Logger wrapper with convenience methods:
    emitEvent, emitFlutterError, emitLifecycleEvent, emitNavigationEvent
  * UILoggerProvider — Flutter-specific LoggerProvider wrapper
  * OTelFlutterFactory overrides loggerProvider for Flutter-specific wrapping
  * FlutterOTel.initialize() now accepts log configuration parameters:
    enableLogs, logRecordExporter, logRecordProcessor, logPrint,
    logPrintLoggerName, enableAutoLogEvents
  * FlutterOTel.logger() and FlutterOTel.loggerProvider static accessors
  * Auto-emits structured OTel log events for lifecycle changes, navigation,
    and errors (opt-out via enableAutoLogEvents: false)
  * Platform-specific log exporters: HTTP for web, gRPC for native
  * Re-exports all dartastic log types for convenience
* Upgraded to dartastic_opentelemetry ^1.0.1-alpha / API ^1.0.0-alpha

## 0.3.4 2025/10/11

* Updated to Dartastic SDK 0.9.2 / API 0.8.8, supports standard env vars and gets OTelLog fixes

## 0.3.3 2025/09/29

* Fixed issues with grpc processor creation, updated to Dartastic 0.8.7

## 0.3.2 2025/06/22

* Doc only, wondrous demo will only live in github, not pub.dev

## 0.3.1 2025/06/17

* Works with Wondrous demo, Dartastic 0.8.6

## 0.3.0

* Initial release
