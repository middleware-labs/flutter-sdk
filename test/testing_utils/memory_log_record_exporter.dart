// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// A memory-based log record exporter for testing purposes.
class MemoryLogRecordExporter implements LogRecordExporter {
  final List<ReadableLogRecord> _exportedLogRecords = [];
  bool _isShutdown = false;

  List<ReadableLogRecord> get exportedLogRecords =>
      List.unmodifiable(_exportedLogRecords);

  void clear() => _exportedLogRecords.clear();

  int get count => _exportedLogRecords.length;

  @override
  Future<ExportResult> export(List<ReadableLogRecord> logRecords) async {
    if (_isShutdown) return ExportResult.failure;
    _exportedLogRecords.addAll(logRecords);
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    _isShutdown = true;
  }

  bool get isShutdown => _isShutdown;
}
