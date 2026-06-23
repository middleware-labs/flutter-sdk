// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

import 'ui_logger.dart';

part 'ui_logger_provider_create.dart';

/// UILoggerProvider wraps the SDK [LoggerProvider] to provide Flutter-specific
/// functionality for log collection in Flutter applications.
///
/// This follows the same wrapper/decorator pattern used by [UITracerProvider]
/// and [UIMeterProvider]. It caches [UILogger] instances by name:version key
/// and delegates all other operations to the underlying SDK LoggerProvider.
///
/// You do not create this directly; it is created by [FlutterOTel.initialize()]
/// via [OTelFlutterFactory].
///
/// Example:
/// ```dart
/// // After FlutterOTel.initialize()
/// final provider = FlutterOTel.loggerProvider;
/// final logger = provider.getLogger('my-feature');
/// logger.info('Feature initialized');
/// ```
class UILoggerProvider implements LoggerProvider {
  final LoggerProvider _delegate;
  final Map<String, UILogger> _loggers = {};

  UILoggerProvider._({required LoggerProvider delegate}) : _delegate = delegate;

  /// Returns a [UILogger] for the given name and version.
  ///
  /// Loggers are cached by `name:version` key so that repeated calls
  /// with the same parameters return the same instance.
  @override
  UILogger getLogger(
    String name, {
    String? version,
    String? schemaUrl,
    Attributes? attributes,
  }) {
    if (isShutdown) {
      throw StateError('LoggerProvider has been shut down');
    }

    final key = '$name:${version ?? ''}';
    return _loggers.putIfAbsent(
      key,
      () => UILoggerCreate.create(
        delegate: _delegate.getLogger(
          name,
          version: version,
          schemaUrl: schemaUrl,
          attributes: attributes,
        ),
      ),
    );
  }

  @override
  void addLogRecordProcessor(LogRecordProcessor processor) {
    _delegate.addLogRecordProcessor(processor);
  }

  @override
  List<LogRecordProcessor> get logRecordProcessors =>
      _delegate.logRecordProcessors;

  @override
  Future<void> forceFlush() => _delegate.forceFlush();

  @override
  Future<bool> shutdown() => _delegate.shutdown();

  @override
  String get endpoint => _delegate.endpoint;

  @override
  set endpoint(String value) => _delegate.endpoint = value;

  @override
  String get serviceName => _delegate.serviceName;

  @override
  set serviceName(String value) => _delegate.serviceName = value;

  @override
  String? get serviceVersion => _delegate.serviceVersion;

  @override
  set serviceVersion(String? value) => _delegate.serviceVersion = value;

  @override
  bool get enabled => _delegate.enabled;

  @override
  set enabled(bool value) => _delegate.enabled = value;

  @override
  bool get isShutdown => _delegate.isShutdown;

  @override
  set isShutdown(bool value) => _delegate.isShutdown = value;

  @override
  Resource? get resource => _delegate.resource;

  @override
  set resource(Resource? value) => _delegate.resource = value;

  @override
  void ensureResourceIsSet() => _delegate.ensureResourceIsSet();
}
