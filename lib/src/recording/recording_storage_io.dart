// Licensed under the Apache License, Version 2.0

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'recording_storage.dart';

/// Filesystem-backed [RecordingStorage] for native platforms (Android, iOS,
/// macOS, Windows, Linux). Screenshots and archives are persisted under the
/// application documents directory so frames from a crashed/closed session can
/// be re-uploaded on the next launch.
class IoRecordingStorage implements RecordingStorage {
  Directory? _screenshotDir;
  Directory? _archiveDir;

  @override
  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _screenshotDir = Directory('${appDir.path}/screenshots');
    _archiveDir = Directory('${appDir.path}/archives');
    for (final dir in [_screenshotDir!, _archiveDir!]) {
      if (!await dir.exists()) await dir.create(recursive: true);
    }
  }

  Future<Directory> _screenshots() async {
    if (_screenshotDir != null) return _screenshotDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/screenshots');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _screenshotDir = dir;
  }

  Future<Directory> _archives() async {
    if (_archiveDir != null) return _archiveDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/archives');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _archiveDir = dir;
  }

  Future<List<String>> _names(Directory dir) async {
    if (!await dir.exists()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList();
  }

  Future<Uint8List?> _read(Directory dir, String name) async {
    final file = File('${dir.path}/$name');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  Future<bool> _delete(Directory dir, String name) async {
    try {
      final file = File('${dir.path}/$name');
      if (await file.exists()) {
        await file.delete();
        return !await file.exists();
      }
      return true; // already gone
    } catch (_) {
      return false;
    }
  }

  Future<DateTime?> _modified(Directory dir, String name) async {
    try {
      final file = File('${dir.path}/$name');
      if (!await file.exists()) return null;
      return file.lastModified();
    } catch (_) {
      return null;
    }
  }

  // ---- Screenshots ----

  @override
  Future<void> writeScreenshot(String name, Uint8List bytes) async {
    final dir = await _screenshots();
    await File('${dir.path}/$name').writeAsBytes(bytes);
  }

  @override
  Future<List<String>> screenshotNames() async => _names(await _screenshots());

  @override
  Future<Uint8List?> readScreenshot(String name) async =>
      _read(await _screenshots(), name);

  @override
  Future<bool> deleteScreenshot(String name) async =>
      _delete(await _screenshots(), name);

  @override
  Future<DateTime?> screenshotModified(String name) async =>
      _modified(await _screenshots(), name);

  // ---- Archives ----

  @override
  Future<void> writeArchive(String name, Uint8List bytes) async {
    final dir = await _archives();
    await File('${dir.path}/$name').writeAsBytes(bytes);
  }

  @override
  Future<List<String>> archiveNames() async => _names(await _archives());

  @override
  Future<Uint8List?> readArchive(String name) async =>
      _read(await _archives(), name);

  @override
  Future<bool> deleteArchive(String name) async =>
      _delete(await _archives(), name);

  @override
  Future<DateTime?> archiveModified(String name) async =>
      _modified(await _archives(), name);
}

RecordingStorage createRecordingStorage() => IoRecordingStorage();
