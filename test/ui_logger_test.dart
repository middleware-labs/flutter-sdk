// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart';

import 'testing_utils/memory_log_record_exporter.dart';
import 'testing_utils/test_otel_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryLogRecordExporter logExporter;

  group('UILogger Tests', () {
    setUp(() async {
      await FlutterOTel.reset();
      logExporter = MemoryLogRecordExporter();
      final processor = SimpleLogRecordProcessor(logExporter);
      await initializeFlutterOTelForTest(
        serviceName: 'ui-logger-test',
        enableLogs: true,
        logRecordProcessor: processor,
        enableAutoLogEvents: false,
      );
    });

    tearDown(() async {
      await FlutterOTel.reset();
    });

    test('FlutterOTel.logger() returns a UILogger', () {
      final logger = FlutterOTel.logger('test');
      expect(logger, isA<UILogger>());
    });

    test('FlutterOTel.loggerProvider returns a UILoggerProvider', () {
      final provider = FlutterOTel.loggerProvider;
      expect(provider, isA<UILoggerProvider>());
    });

    test('UILogger delegates emit to SDK Logger', () {
      final logger = FlutterOTel.logger('test');
      logger.emit(
        severityNumber: Severity.INFO,
        severityText: 'INFO',
        body: 'Test log message',
      );

      expect(logExporter.count, equals(1));
      final record = logExporter.exportedLogRecords.first;
      expect(record.body, equals('Test log message'));
      expect(record.severityNumber, equals(Severity.INFO));
    });

    test('UILogger convenience methods emit correct severity', () {
      final logger = FlutterOTel.logger('test');

      logger.trace('trace msg');
      logger.debug('debug msg');
      logger.info('info msg');
      logger.warn('warn msg');
      logger.error('error msg');
      logger.fatal('fatal msg');

      expect(logExporter.count, equals(6));

      final records = logExporter.exportedLogRecords;
      expect(records[0].severityNumber, equals(Severity.TRACE));
      expect(records[1].severityNumber, equals(Severity.DEBUG));
      expect(records[2].severityNumber, equals(Severity.INFO));
      expect(records[3].severityNumber, equals(Severity.WARN));
      expect(records[4].severityNumber, equals(Severity.ERROR));
      expect(records[5].severityNumber, equals(Severity.FATAL));
    });

    test('UILogger.emitEvent emits structured event with EventName', () {
      final logger = FlutterOTel.logger('test');
      logger.emitEvent(
        'user.action',
        body: 'Button tapped',
        attributes: {'button.id': 'submit'}.toAttributes(),
      );

      expect(logExporter.count, equals(1));
      final record = logExporter.exportedLogRecords.first;
      expect(record.eventName, equals('user.action'));
      expect(record.body, equals('Button tapped'));
      expect(record.severityNumber, equals(Severity.INFO));
    });

    test('UILogger.emitEvent supports custom severity', () {
      final logger = FlutterOTel.logger('test');
      logger.emitEvent(
        'system.warning',
        body: 'Low memory',
        severity: Severity.WARN,
      );

      expect(logExporter.count, equals(1));
      final record = logExporter.exportedLogRecords.first;
      expect(record.severityNumber, equals(Severity.WARN));
    });

    test(
      'UILogger.emitFlutterError emits error with structured attributes',
      () {
        final logger = FlutterOTel.logger('test');
        final details = FlutterErrorDetails(
          exception: StateError('Test error'),
          stack: StackTrace.current,
          context: ErrorDescription('during test'),
        );

        logger.emitFlutterError(details);

        expect(logExporter.count, equals(1));
        final record = logExporter.exportedLogRecords.first;
        expect(record.eventName, equals('device.app.error'));
        expect(record.severityNumber, equals(Severity.ERROR));
        expect(record.body.toString(), contains('Flutter error'));
      },
    );

    test('UILogger.emitLifecycleEvent emits lifecycle event', () {
      final logger = FlutterOTel.logger('test');
      logger.emitLifecycleEvent(
        'paused',
        previousState: 'active',
        duration: Duration(seconds: 30),
      );

      expect(logExporter.count, equals(1));
      final record = logExporter.exportedLogRecords.first;
      expect(record.eventName, equals('device.app.lifecycle'));
      expect(record.body.toString(), contains('paused'));
    });

    test('UILogger.emitNavigationEvent emits navigation event', () {
      final logger = FlutterOTel.logger('test');
      logger.emitNavigationEvent(
        '/settings',
        fromRoute: '/home',
        action: 'push',
      );

      expect(logExporter.count, equals(1));
      final record = logExporter.exportedLogRecords.first;
      expect(record.eventName, equals('browser.navigation'));
      expect(record.body.toString(), contains('/home'));
      expect(record.body.toString(), contains('/settings'));
    });

    test('UILogger name and version are delegated', () {
      final logger = FlutterOTel.logger('my-logger');
      expect(logger.name, equals('my-logger'));
    });

    test('UILoggerProvider caches loggers by name:version', () {
      final provider = FlutterOTel.loggerProvider;
      final logger1 = provider.getLogger('test', version: '1.0');
      final logger2 = provider.getLogger('test', version: '1.0');
      final logger3 = provider.getLogger('test', version: '2.0');

      expect(identical(logger1, logger2), isTrue);
      expect(identical(logger1, logger3), isFalse);
    });
  });

  group('Auto Log Events Tests', () {
    late MemoryLogRecordExporter logExporter;

    setUp(() async {
      await FlutterOTel.reset();
      logExporter = MemoryLogRecordExporter();
      final processor = SimpleLogRecordProcessor(logExporter);
      await initializeFlutterOTelForTest(
        serviceName: 'auto-log-test',
        enableLogs: true,
        logRecordProcessor: processor,
        enableAutoLogEvents: true,
      );
    });

    tearDown(() async {
      await FlutterOTel.reset();
    });

    test('Lifecycle changes emit log events when enabled', () {
      // The OTelLifecycleObserver was created during initialize,
      // which already emitted the initial lifecycle event.
      // Count those initial events.
      final initialCount = logExporter.count;

      // Trigger a lifecycle change
      final observer = FlutterOTel.lifecycleObserver;
      observer.didChangeAppLifecycleState(AppLifecycleState.paused);

      // Should have emitted at least one more log event
      expect(logExporter.count, greaterThan(initialCount));

      // Find the lifecycle log event
      final lifecycleRecords =
          logExporter.exportedLogRecords
              .where((r) => r.eventName == 'device.app.lifecycle')
              .toList();
      expect(lifecycleRecords, isNotEmpty);
    });

    test('enableAutoLogEvents can be disabled', () async {
      await FlutterOTel.reset();
      logExporter = MemoryLogRecordExporter();
      final processor = SimpleLogRecordProcessor(logExporter);
      await initializeFlutterOTelForTest(
        serviceName: 'no-auto-log-test',
        enableLogs: true,
        logRecordProcessor: processor,
        enableAutoLogEvents: false,
      );

      expect(FlutterOTel.enableAutoLogEvents, isFalse);
    });
  });
}
