// Licensed under the Apache License, Version 2.0

import 'package:flutter/foundation.dart';

import 'recording_storage.dart';

/// In-memory [RecordingStorage] for Flutter web.
///
/// Browsers have no application-documents directory and `dart:io` is
/// unavailable, so screenshots and archives are held in memory for the lifetime
/// of the page. They are uploaded on the normal cadence; only frames that have
/// not yet been flushed when the tab is closed/reloaded are lost (there is no
/// cross-reload persistence, which is acceptable for session replay).
///
/// Because there is no disk to spill to, the in-memory buffers are capped so a
/// stalled or offline upload pipeline cannot grow RAM without bound. When a cap
/// is exceeded the OLDEST entries are dropped first (FIFO) — under sustained
/// backpressure we'd rather lose the oldest replay frames than the app's memory.
class _Entry {
  final Uint8List bytes;
  final DateTime modified;

  _Entry(this.bytes) : modified = DateTime.now();
}

class WebRecordingStorage implements RecordingStorage {
  /// Screenshots are short-lived (archived every `archiveChunkSize` frames), so
  /// this only needs to absorb a transient burst. ~8 MB ≈ hundreds of frames.
  static const int _maxScreenshotBytes = 8 * 1024 * 1024;

  /// Archives wait here until uploaded. ~32 MB is generous headroom (minutes of
  /// backlog at typical frame sizes) while still being a hard ceiling.
  static const int _maxArchiveBytes = 32 * 1024 * 1024;

  // LinkedHashMap iteration order == insertion order, and names are generated in
  // chronological order, so `keys.first` is always the oldest entry to evict.
  final Map<String, _Entry> _screenshots = {};
  final Map<String, _Entry> _archives = {};
  int _screenshotBytes = 0;
  int _archiveBytes = 0;

  @override
  Future<void> init() async {}

  // ---- Screenshots ----

  @override
  Future<void> writeScreenshot(String name, Uint8List bytes) async {
    final prev = _screenshots.remove(name);
    if (prev != null) _screenshotBytes -= prev.bytes.length;
    _screenshots[name] = _Entry(bytes);
    _screenshotBytes += bytes.length;
    _evict(_screenshots, _maxScreenshotBytes, isArchive: false);
  }

  @override
  Future<List<String>> screenshotNames() async => _screenshots.keys.toList();

  @override
  Future<Uint8List?> readScreenshot(String name) async =>
      _screenshots[name]?.bytes;

  @override
  Future<bool> deleteScreenshot(String name) async {
    final removed = _screenshots.remove(name);
    if (removed == null) return false;
    _screenshotBytes -= removed.bytes.length;
    return true;
  }

  @override
  Future<DateTime?> screenshotModified(String name) async =>
      _screenshots[name]?.modified;

  // ---- Archives ----

  @override
  Future<void> writeArchive(String name, Uint8List bytes) async {
    final prev = _archives.remove(name);
    if (prev != null) _archiveBytes -= prev.bytes.length;
    _archives[name] = _Entry(bytes);
    _archiveBytes += bytes.length;
    _evict(_archives, _maxArchiveBytes, isArchive: true);
  }

  @override
  Future<List<String>> archiveNames() async => _archives.keys.toList();

  @override
  Future<Uint8List?> readArchive(String name) async => _archives[name]?.bytes;

  @override
  Future<bool> deleteArchive(String name) async {
    final removed = _archives.remove(name);
    if (removed == null) return false;
    _archiveBytes -= removed.bytes.length;
    return true;
  }

  @override
  Future<DateTime?> archiveModified(String name) async =>
      _archives[name]?.modified;

  /// Drops oldest entries until [map] is within [maxBytes]. Keeps at least the
  /// just-written entry even if it alone exceeds the cap.
  void _evict(Map<String, _Entry> map, int maxBytes, {required bool isArchive}) {
    var current = isArchive ? _archiveBytes : _screenshotBytes;
    var dropped = 0;
    while (current > maxBytes && map.length > 1) {
      final oldest = map.keys.first;
      final removed = map.remove(oldest);
      if (removed == null) break;
      current -= removed.bytes.length;
      dropped++;
    }
    if (isArchive) {
      _archiveBytes = current;
    } else {
      _screenshotBytes = current;
    }
    if (dropped > 0 && kDebugMode) {
      debugPrint(
        'Session replay (web): memory cap reached, dropped $dropped oldest '
        '${isArchive ? 'archive(s)' : 'screenshot(s)'} to stay under '
        '${(maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB',
      );
    }
  }
}

RecordingStorage createRecordingStorage() => WebRecordingStorage();
