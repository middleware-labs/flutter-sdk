// Licensed under the Apache License, Version 2.0

import 'dart:typed_data';

// Platform-specific factory. Native (VM/mobile/desktop) uses a filesystem-backed
// implementation; web (no dart:io / no path_provider) falls back to an in-memory
// store so session replay still works in the browser.
import 'recording_storage_io.dart'
    if (dart.library.html) 'recording_storage_web.dart'
    if (dart.library.js_interop) 'recording_storage_web.dart'
    as impl;

/// Storage abstraction for session-replay screenshots and archives.
///
/// Screenshots and archives are addressed by an opaque [String] name (the
/// [MiddlewareScreenshotManager] is responsible for choosing names such as
/// `"<timestamp>.jpeg"` or `"<sessionId>-<lastTs>.tar.gz"`).
///
/// Two implementations exist, selected at compile time via conditional import:
///
/// - Native: persists to `<appDocs>/screenshots` and `<appDocs>/archives` using
///   `dart:io` + `path_provider`. Survives app restarts so stale frames from a
///   previous launch can still be uploaded.
/// - Web: keeps everything in memory because the browser has no app-documents
///   directory. Frames captured during the current page lifetime are uploaded
///   normally; nothing persists across a page reload (acceptable for replay).
abstract class RecordingStorage {
  /// Prepares any backing directories / structures. Called once from
  /// [MiddlewareScreenshotManager.start].
  Future<void> init();

  // ---- Screenshots ----

  Future<void> writeScreenshot(String name, Uint8List bytes);

  Future<List<String>> screenshotNames();

  Future<Uint8List?> readScreenshot(String name);

  Future<bool> deleteScreenshot(String name);

  Future<DateTime?> screenshotModified(String name);

  // ---- Archives ----

  Future<void> writeArchive(String name, Uint8List bytes);

  Future<List<String>> archiveNames();

  Future<Uint8List?> readArchive(String name);

  Future<bool> deleteArchive(String name);

  Future<DateTime?> archiveModified(String name);
}

/// Returns the platform-appropriate [RecordingStorage] implementation.
RecordingStorage createRecordingStorage() => impl.createRecordingStorage();
