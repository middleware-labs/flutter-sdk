import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Callback for screenshot capture
typedef ScreenshotCallback = void Function(Uint8List imageData);

/// Network callback interface
abstract class NetworkCallback {
  void onSuccess(String response);

  void onError(Exception error);
}

/// Recording options configuration
class RecordingOptions {
  final Duration screenshotInterval;
  final int qualityValue;
  final int minResolution;
  final int archiveChunkSize;
  final Duration staleArchiveMaxAge;
  final Duration staleScreenshotMaxAge;
  final bool uploadStaleFilesOnStart;

  const RecordingOptions({
    this.screenshotInterval = const Duration(seconds: 2),
    this.qualityValue = 80,
    this.minResolution = 320,
    this.archiveChunkSize = 10,
    this.staleArchiveMaxAge = const Duration(seconds: 59),
    this.staleScreenshotMaxAge = const Duration(seconds: 59),
    this.uploadStaleFilesOnStart = true,
  });
}

/// Middleware configuration builder
class MiddlewareBuilder {
  final String target;
  final String rumAccessToken;
  final RecordingOptions recordingOptions;

  MiddlewareBuilder({
    required this.target,
    required this.rumAccessToken,
    this.recordingOptions = const RecordingOptions(),
  });
}

/// Network manager for sending screenshots
class NetworkManager {
  static const String _imagesUrl = '/v1/rum';

  final String baseUrl;
  final String token;
  final http.Client _client;

  NetworkManager(this.baseUrl, this.token) : _client = http.Client();

  /// Send compressed screenshot archive to server
  Future<void> sendImages(
    String sessionId,
    Uint8List imageData,
    String fileName,
    NetworkCallback callback,
  ) async {
    if (token.isEmpty) {
      callback.onError(Exception('Token is empty'));
      return;
    }

    try {
      final url = Uri.parse('$baseUrl$_imagesUrl');

      // The imageData is already gzip compressed from archiveFolder
      // Create multipart request with the gzipped tar archive
      final request =
          http.MultipartRequest('POST', url)
            ..headers['Authorization'] = token
            ..fields['sessionId'] = sessionId
            ..files.add(
              http.MultipartFile.fromBytes(
                'batch',
                imageData,
                filename: fileName,
                contentType: http.MediaType('application', 'gzip'),
              ),
            );

      if (kDebugMode) {
        debugPrint(
          'Uploading session replay: $fileName (${imageData.length} bytes)',
        );
      }

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (kDebugMode) {
          debugPrint('Upload successful: ${response.statusCode}');
        }
        callback.onSuccess(response.body);
      } else {
        if (kDebugMode) {
          debugPrint(
            'Upload failed: ${response.statusCode} - ${response.body}',
          );
        }
        callback.onError(
          Exception('Upload failed with status: ${response.statusCode}'),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Network error: $e');
      }
      callback.onError(Exception('Network error: $e'));
    }
  }

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}

/// Main screenshot manager for Flutter
class MiddlewareScreenshotManager {
  String _firstTs = '';
  String _lastTs = '';
  final MiddlewareBuilder builder;
  final String sessionId;
  final GlobalKey repaintBoundaryKey;

  Timer? _screenshotTimer;
  Timer? _uploadTimer;
  final List<GlobalKey> _sanitizedElements = [];
  Orientation? _lastOrientation;
  bool _isRunning = false;

  MiddlewareScreenshotManager({
    required this.builder,
    required this.sessionId,
    required this.repaintBoundaryKey,
  });

  /// Start capturing screenshots
  Future<void> start(int startTs) async {
    if (_isRunning) return;

    _firstTs = startTs.toString();
    _isRunning = true;
    _lastOrientation = null;
    // Clean up any stale archives from previous sessions before starting
    await _cleanupStaleArchives();

    // Schedule screenshot capture
    _screenshotTimer = Timer.periodic(
      builder.recordingOptions.screenshotInterval,
      (_) => _makeScreenshotAndSaveWithArchive(),
    );

    // Schedule upload
    _uploadTimer = Timer.periodic(
      builder.recordingOptions.screenshotInterval,
      (_) => sendScreenshots(),
    );

    // Take first screenshot immediately
    await _makeScreenshotAndSaveWithArchive();

    // Send any existing archives after a short delay
    Timer(Duration(seconds: 2), () => sendScreenshots());
  }

  /// Clean up stale archives and screenshots from previous sessions
  /// This handles cases where the app was closed before uploads completed
  Future<void> _cleanupStaleArchives() async {
    if (!builder.recordingOptions.uploadStaleFilesOnStart) {
      if (kDebugMode) {
        debugPrint('Stale file upload disabled by configuration');
      }
      return;
    }

    try {
      if (kDebugMode) {
        debugPrint('Checking for stale files from previous sessions...');
      }

      // Check for stale archives
      final archiveFolder = await _getArchiveFolder();
      if (await archiveFolder.exists()) {
        final archives = archiveFolder.listSync().whereType<File>().toList();

        if (archives.isNotEmpty) {
          if (kDebugMode) {
            debugPrint(
              'Found ${archives.length} stale archive(s) from previous session',
            );
          }

          // Try to upload stale archives
          final staleUploadSuccess = await _uploadStaleArchives(archives);

          if (!staleUploadSuccess) {
            // If upload fails, check age and delete old ones
            await _deleteOldArchives(
              archives,
              maxAge: builder.recordingOptions.staleArchiveMaxAge,
            );
          }
        }
      }

      // Check for stale screenshots
      final screenshotFolder = await _getScreenshotFolder();
      if (await screenshotFolder.exists()) {
        final screenshots =
            screenshotFolder.listSync().whereType<File>().toList();

        if (screenshots.isNotEmpty) {
          if (kDebugMode) {
            debugPrint(
              'Found ${screenshots.length} stale screenshot(s) from previous session',
            );
          }

          // Archive old screenshots if there are enough
          if (screenshots.length >= builder.recordingOptions.archiveChunkSize) {
            await _archiveFolder(screenshotFolder);
          } else {
            // Delete individual old screenshots
            await _deleteOldScreenshots(
              screenshots,
              maxAge: builder.recordingOptions.staleScreenshotMaxAge,
            );
          }
        }
      }

      if (kDebugMode) {
        debugPrint('Stale file cleanup completed');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error during stale file cleanup: $e');
      }
    }
  }

  Future<bool> _uploadStaleArchives(List<File> archives) async {
    if (sessionId.isEmpty) return false;

    try {
      if (kDebugMode) {
        debugPrint(
          'Attempting to upload ${archives.length} stale archive(s)...',
        );
      }

      final networkManager = NetworkManager(
        builder.target,
        builder.rumAccessToken,
      );
      int successCount = 0;

      for (final archive in archives) {
        try {
          final fileName = archive.uri.pathSegments.last;
          // Check if archive is from current session or a different one
          if (fileName.startsWith(sessionId)) {
            // Same session - definitely upload
            if (kDebugMode) {
              debugPrint(
                'Uploading stale archive from current session: $fileName',
              );
            }
          } else {
            // Different session - check age
            final modified = await archive.lastModified();
            final age = DateTime.now().difference(modified);

            if (age > Duration(seconds: 59)) {
              // Too old, delete it
              if (kDebugMode) {
                debugPrint(
                  'Deleting very old archive: $fileName (${age.inHours}h old)',
                );
              }
              await _deleteFileSafely(archive);
              continue;
            }

            if (kDebugMode) {
              debugPrint(
                'Uploading stale archive from previous session: $fileName',
              );
            }
          }

          final imageData = await archive.readAsBytes();
          final completer = Completer<bool>();
          final staleSessionId = fileName.split('-')[0];

          await networkManager.sendImages(
            staleSessionId,
            imageData,
            fileName,
            _NetworkCallbackImpl(
              onSuccessCallback: (response) async {
                await _deleteFileSafely(archive);
                successCount++;
                completer.complete(true);
              },
              onErrorCallback: (e) {
                if (kDebugMode) {
                  debugPrint('Failed to upload stale archive: $e');
                }
                completer.complete(false);
              },
            ),
          );

          await completer.future.timeout(
            Duration(seconds: 30),
            onTimeout: () {
              if (kDebugMode) {
                debugPrint('Timeout uploading stale archive: $fileName');
              }
              return false;
            },
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Error uploading stale archive: $e');
          }
        }
      }

      networkManager.dispose();

      if (kDebugMode) {
        debugPrint(
          'Stale archive upload: $successCount/${archives.length} succeeded',
        );
      }

      return successCount > 0;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error in stale archive upload: $e');
      }
      return false;
    }
  }

  /// Delete archives older than maxAge
  Future<void> _deleteOldArchives(
    List<File> archives, {
    required Duration maxAge,
  }) async {
    final now = DateTime.now();
    int deletedCount = 0;

    for (final archive in archives) {
      try {
        final modified = await archive.lastModified();
        final age = now.difference(modified);

        if (age > maxAge) {
          if (kDebugMode) {
            debugPrint(
              'Deleting old archive: ${archive.uri.pathSegments.last} (${age.inHours}h old)',
            );
          }
          if (await _deleteFileSafely(archive)) {
            deletedCount++;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error checking archive age: $e');
        }
      }
    }

    if (kDebugMode && deletedCount > 0) {
      debugPrint('Deleted $deletedCount old archive(s)');
    }
  }

  /// Delete screenshots older than maxAge
  Future<void> _deleteOldScreenshots(
    List<File> screenshots, {
    required Duration maxAge,
  }) async {
    final now = DateTime.now();
    int deletedCount = 0;

    for (final screenshot in screenshots) {
      try {
        final modified = await screenshot.lastModified();
        final age = now.difference(modified);

        if (age > maxAge) {
          if (kDebugMode) {
            debugPrint(
              'Deleting old screenshot: ${screenshot.uri.pathSegments.last} (${age.inMinutes}m old)',
            );
          }
          if (await _deleteFileSafely(screenshot)) {
            deletedCount++;
          }
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Error checking screenshot age: $e');
        }
      }
    }

    if (kDebugMode && deletedCount > 0) {
      debugPrint('Deleted $deletedCount old screenshot(s)');
    }
  }

  /// Stop capturing screenshots
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;
    _screenshotTimer?.cancel();
    _uploadTimer?.cancel();

    await _terminate();
    _sanitizedElements.clear();
    _lastOrientation = null;
  }

  /// Capture and save screenshot
  Future<void> _makeScreenshotAndSaveWithArchive() async {
    try {
      _checkAndReportOrientationChange();

      final screenshotData = await _captureScreenshot();
      if (screenshotData == null) return;

      final screenshotFolder = await _getScreenshotFolder();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final screenshotFile = File('${screenshotFolder.path}/$timestamp.jpeg');

      await screenshotFile.writeAsBytes(screenshotData);

      // Check if we need to archive
      final files = screenshotFolder.listSync();
      if (files.length >= builder.recordingOptions.archiveChunkSize) {
        await _archiveFolder(screenshotFolder);
      }
    } catch (e) {
      debugPrint('Error making screenshot: $e');
    }
  }

  /// Capture screenshot from RepaintBoundary
  Future<Uint8List?> _captureScreenshot() async {
    try {
      final boundary =
          repaintBoundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;

      if (boundary == null) {
        debugPrint('RepaintBoundary not found');
        return null;
      }

      // Capture the image
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

      if (byteData == null) return null;

      // Apply masking if needed
      final maskedImage = await _applyMaskToScreenshot(image);

      // Compress and return
      return await _compress(maskedImage);
    } catch (e) {
      debugPrint('Error capturing screenshot: $e');
      return null;
    }
  }

  /// Compress screenshot
  Future<Uint8List> _compress(ui.Image originalImage) async {
    final originalWidth = originalImage.width;
    final originalHeight = originalImage.height;
    final aspectRatio = originalWidth / originalHeight;

    int newWidth, newHeight;
    final minResolution = builder.recordingOptions.minResolution;

    if (originalWidth < originalHeight) {
      newWidth = minResolution;
      newHeight = (newWidth / aspectRatio).round();
    } else {
      newHeight = minResolution;
      newWidth = (newHeight * aspectRatio).round();
    }

    debugPrint(
      'Screenshot scaling: ${originalWidth}x$originalHeight -> ${newWidth}x$newHeight',
    );

    // Create a scaled picture recorder
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..filterQuality = FilterQuality.medium;

    canvas.drawImageRect(
      originalImage,
      Rect.fromLTWH(0, 0, originalWidth.toDouble(), originalHeight.toDouble()),
      Rect.fromLTWH(0, 0, newWidth.toDouble(), newHeight.toDouble()),
      paint,
    );

    final picture = recorder.endRecording();
    final scaledImage = await picture.toImage(newWidth, newHeight);
    final byteData = await scaledImage.toByteData(
      format: ui.ImageByteFormat.png,
    );

    return byteData!.buffer.asUint8List();
  }

  /// Apply masking to sanitized elements
  Future<ui.Image> _applyMaskToScreenshot(ui.Image image) async {
    if (_sanitizedElements.isEmpty) return image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint();

    // Draw original image
    canvas.drawImage(image, Offset.zero, paint);

    // Draw masks over sanitized elements
    final maskPaint = _getMaskPaint();
    for (final key in _sanitizedElements) {
      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.attached) {
        final position = renderBox.localToGlobal(Offset.zero);
        final size = renderBox.size;

        canvas.drawRect(
          Rect.fromLTWH(position.dx, position.dy, size.width, size.height),
          maskPaint,
        );
      }
    }

    final picture = recorder.endRecording();
    return await picture.toImage(image.width, image.height);
  }

  /// Create mask paint with striped pattern
  Paint _getMaskPaint() {
    final paint = Paint()..style = PaintingStyle.fill;

    // Create a black gray overlay (pattern creation would require custom implementation)

    paint.color = Colors.black45;

    return paint;
  }

  /// Get screenshot folder
  Future<Directory> _getScreenshotFolder() async {
    final appDir = await getApplicationDocumentsDirectory();
    final screenshotDir = Directory('${appDir.path}/screenshots');
    if (!await screenshotDir.exists()) {
      await screenshotDir.create(recursive: true);
    }
    return screenshotDir;
  }

  /// Archive screenshots into tar.gz
  Future<void> _archiveFolder(Directory folder) async {
    try {
      final screenshots = folder.listSync().whereType<File>().toList();
      if (screenshots.isEmpty) {
        debugPrint('No screenshots to archive');
        return;
      }

      screenshots.sort(
        (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
      );

      final archive = Archive();

      for (final screenshot in screenshots) {
        _lastTs = _getNameWithoutExtension(screenshot);
        final filename =
            '${_firstTs}_1_${_getNameWithoutExtension(screenshot)}.jpeg';
        final bytes = await screenshot.readAsBytes();

        archive.addFile(ArchiveFile(filename, bytes.length, bytes));
      }

      final tarEncoder = TarEncoder();
      final tarData = tarEncoder.encode(archive);
      final gzipData = GZipEncoder().encode(tarData);

      final archiveFolder = await _getArchiveFolder();
      final archiveFile = File(
        '${archiveFolder.path}/$sessionId-$_lastTs.tar.gz',
      );

      await archiveFile.writeAsBytes(gzipData);

      // Delete original screenshots
      for (final screenshot in screenshots) {
        await screenshot.delete();
      }
    } catch (e) {
      debugPrint('Error archiving folder: $e');
    }
  }

  /// Get archive folder
  Future<Directory> _getArchiveFolder() async {
    final appDir = await getApplicationDocumentsDirectory();
    final archiveDir = Directory('${appDir.path}/archives');
    if (!await archiveDir.exists()) {
      await archiveDir.create(recursive: true);
    }
    return archiveDir;
  }

  /// Send screenshots to server
  Future<void> sendScreenshots() async {
    if (sessionId.isEmpty) {
      debugPrint('SessionId is empty');
      return;
    }

    try {
      final archiveFolder = await _getArchiveFolder();
      final archives = archiveFolder.listSync().whereType<File>().toList();

      if (archives.isEmpty) {
        if (kDebugMode) {
          debugPrint('No archives to upload');
        }
        return;
      }

      if (kDebugMode) {
        debugPrint('Found ${archives.length} archive(s) to upload');
        for (final archive in archives) {
          debugPrint(
            '  - ${archive.uri.pathSegments.last} (${await archive.length()} bytes)',
          );
        }
      }

      final networkManager = NetworkManager(
        builder.target,
        builder.rumAccessToken,
      );

      // Process archives sequentially to avoid race conditions
      int successCount = 0;
      int failCount = 0;

      for (final archive in archives) {
        try {
          final imageData = await archive.readAsBytes();
          final fileName = archive.uri.pathSegments.last;

          if (kDebugMode) {
            debugPrint(
              '[$successCount/${archives.length}] Sending archive: $fileName',
            );
          }

          // Use a Completer to wait for the callback
          final completer = Completer<bool>();

          await networkManager.sendImages(
            sessionId,
            imageData,
            fileName,
            _NetworkCallbackImpl(
              onSuccessCallback: (response) async {
                if (kDebugMode) {
                  debugPrint('✓ Upload successful: $fileName');
                }
                try {
                  // Use the safe delete helper
                  final deleted = await _deleteFileSafely(archive);
                  if (deleted) {
                    successCount++;
                  } else {
                    failCount++;
                    if (kDebugMode) {
                      debugPrint('✗ Failed to delete $fileName after upload');
                    }
                  }
                  completer.complete(deleted);
                } catch (e) {
                  if (kDebugMode) {
                    debugPrint('✗ Error in delete callback for $fileName: $e');
                  }
                  failCount++;
                  completer.complete(false);
                }
              },
              onErrorCallback: (e) {
                if (kDebugMode) {
                  debugPrint('✗ Upload failed for $fileName: $e');
                }
                failCount++;
                completer.complete(false);
              },
            ),
          );

          // Wait for the upload to complete before moving to next file
          await completer.future;
        } catch (e) {
          if (kDebugMode) {
            debugPrint('✗ Error processing archive ${archive.path}: $e');
          }
          failCount++;
        }
      }

      if (kDebugMode) {
        debugPrint(
          'Upload summary: $successCount succeeded, $failCount failed',
        );
      }

      networkManager.dispose();
    } catch (e) {
      debugPrint('Error sending screenshot archives: $e');
    }
  }

  Future<bool> _deleteFileSafely(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();

        // Verify deletion
        if (await file.exists()) {
          if (kDebugMode) {
            debugPrint('File still exists after delete attempt: ${file.path}');
          }
          return false;
        }

        if (kDebugMode) {
          debugPrint('Successfully deleted: ${file.path}');
        }
        return true;
      } else {
        if (kDebugMode) {
          debugPrint('File does not exist: ${file.path}');
        }
        return true; // Already gone, consider it success
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error deleting file ${file.path}: $e');
      }
      return false;
    }
  }

  /// Add view to sanitization list
  void setViewForBlur(GlobalKey key) {
    _sanitizedElements.add(key);
  }

  /// Remove sanitized element
  void removeSanitizedElement(GlobalKey key) {
    _sanitizedElements.remove(key);
  }

  /// Check and report orientation changes
  void _checkAndReportOrientationChange() {
    final context = repaintBoundaryKey.currentContext;
    if (context == null) return;

    final orientation = MediaQuery.of(context).orientation;
    if (orientation != _lastOrientation) {
      _lastOrientation = orientation;
      debugPrint('Current orientation: $orientation');
    }
  }

  /// Terminate and cleanup
  Future<void> _terminate() async {
    try {
      final screenshotFolder = await _getScreenshotFolder();
      await _archiveFolder(screenshotFolder);
      await sendScreenshots();
    } catch (e) {
      debugPrint('Error during termination: $e');
    }
  }

  /// Get filename without extension
  String _getNameWithoutExtension(File file) {
    final name = file.uri.pathSegments.last;
    final lastDot = name.lastIndexOf('.');
    return lastDot > 0 ? name.substring(0, lastDot) : name;
  }
}

/// Network callback implementation
class _NetworkCallbackImpl implements NetworkCallback {
  final void Function(String) onSuccessCallback;
  final void Function(Exception) onErrorCallback;

  _NetworkCallbackImpl({
    required this.onSuccessCallback,
    required this.onErrorCallback,
  });

  @override
  void onSuccess(String response) => onSuccessCallback(response);

  @override
  void onError(Exception error) => onErrorCallback(error);
}

/// Widget wrapper with RepaintBoundary for screenshot capture
class ScreenshotRecordingWrapper extends StatefulWidget {
  final Widget child;
  final MiddlewareScreenshotManager? manager;

  const ScreenshotRecordingWrapper({
    super.key,
    required this.child,
    this.manager,
  });

  @override
  State<ScreenshotRecordingWrapper> createState() =>
      _ScreenshotRecordingWrapperState();
}

class _ScreenshotRecordingWrapperState
    extends State<ScreenshotRecordingWrapper> {
  @override
  Widget build(BuildContext context) {
    if (widget.manager != null) {
      return RepaintBoundary(
        key: widget.manager!.repaintBoundaryKey,
        child: widget.child,
      );
    }
    return widget.child;
  }
}
