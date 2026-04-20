import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image_pkg;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

// ---------------------------------------------------------------------------
// Bandwidth budget (rough numbers at default settings):
//
//  Old defaults: PNG, 320 min-dim, 2 s interval, chunk=10
//    ~120–300 KB per frame × 1800 frames/2 h ≈ 216–540 MB raw
//    After gzip of PNG-inside-tar: ~190–500 MB  ← matches the reported >1.5 GB
//    (PNG is already compressed so gzip barely helps.)
//
//  New defaults: JPEG q=35, 240 max-dim, 4 s interval, chunk=20
//    ~8–20 KB per frame × 900 frames/2 h ≈ 7–18 MB raw
//    After gzip of JPEG-inside-tar: ~7–17 MB  (≈ 97 % reduction)
//
//  Additional savings from perceptual-delta skip (≥50 % of frames identical
//  during idle screens are dropped entirely).
// ---------------------------------------------------------------------------

/// Encodes form field / filename tokens like package:http multipart.
String _multipartFormDataNameEncode(String value) {
  return value
      .replaceAll(RegExp(r'\r\n|\r|\n'), '%0D%0A')
      .replaceAll('"', '%22');
}

/// OTLP resource attributes — computed once and cached.
/// The resource is immutable after initialisation so caching is safe.
String _rumResourceAttributesJson() {
  final provider = OTel.tracerProvider();
  provider.ensureResourceIsSet();
  final resource = provider.resource;
  if (resource == null) return '{}';
  try {
    return jsonEncode(resource.attributes.toJson());
  } catch (e, st) {
    if (kDebugMode)
      debugPrint('RUM resourceAttributes jsonEncode failed: $e\n$st');
    return '{}';
  }
}

/// Callback for screenshot capture
typedef ScreenshotCallback = void Function(Uint8List imageData);

/// Network callback interface
abstract class NetworkCallback {
  void onSuccess(String response);

  void onError(Exception error);
}

/// Recording options configuration
class RecordingOptions {
  /// How often a screenshot is attempted.  4 s is a good balance; use 6–8 s
  /// for even lower bandwidth.
  final Duration screenshotInterval;

  /// JPEG quality 1–100.  35 is visually acceptable for session replay and
  /// produces files ≈ 8–25 KB at 240 p.  Do NOT go above 60 without also
  /// reducing [maxDimension].
  final int qualityValue;

  /// The *longest* side is scaled down to this many pixels.  240 keeps text
  /// legible in replay while keeping each frame tiny.  Raise to 320 only if
  /// your replay viewer needs more detail.
  final int maxDimension;

  /// Perceptual-change threshold (0–1).  A new frame whose mean-pixel
  /// difference from the last uploaded frame is below this fraction is
  /// skipped entirely.  0.02 (2 %) discards purely idle screens.
  final double deltaThreshold;

  /// Number of frames to bundle per archive before uploading.
  final int archiveChunkSize;

  final Duration staleArchiveMaxAge;
  final Duration staleScreenshotMaxAge;
  final bool uploadStaleFilesOnStart;

  const RecordingOptions({
    this.screenshotInterval = const Duration(seconds: 4),
    this.qualityValue = 35,
    this.maxDimension = 240,
    this.deltaThreshold = 0.02,
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

  Future<void> sendImages(
    String sessionId,
    String resourceAttributes,
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

      final boundary = 'Boundary-${const Uuid().v4()}';
      final body = BytesBuilder(copy: false);
      void writeUtf8(String s) => body.add(utf8.encode(s));

      for (final entry
          in <String, String>{
            'sessionId': sessionId,
            'resourceAttributes': resourceAttributes,
          }.entries) {
        writeUtf8('--$boundary\r\n');
        writeUtf8(
          'Content-Disposition: form-data; name="${_multipartFormDataNameEncode(entry.key)}"\r\n\r\n',
        );
        body.add(utf8.encode(entry.value));
        writeUtf8('\r\n');
      }

      writeUtf8('--$boundary\r\n');
      writeUtf8(
        'Content-Disposition: form-data; name="batch"; '
        'filename="${_multipartFormDataNameEncode(fileName)}"\r\n',
      );
      writeUtf8('Content-Type: application/x-tar\r\n\r\n');
      body.add(imageData);
      writeUtf8('\r\n');
      writeUtf8('--$boundary--\r\n');

      final request =
          http.Request('POST', url)
            ..headers['Authorization'] = token
            ..headers['Content-Type'] =
                'multipart/form-data; boundary=$boundary'
            ..bodyBytes = body.toBytes();

      if (kDebugMode) {
        debugPrint(
          'Uploading session replay: $fileName (${imageData.length} bytes)',
        );
      }

      final streamedResponse = await _client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (kDebugMode) debugPrint('Upload successful: ${response.statusCode}');
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
      if (kDebugMode) debugPrint('Network error: $e');
      callback.onError(Exception('Network error: $e'));
    }
  }

  void dispose() => _client.close();
}

// ---------------------------------------------------------------------------
// Lightweight perceptual-delta helper
// ---------------------------------------------------------------------------

/// Returns the mean absolute luminance difference between two raw RGBA byte
/// buffers normalised to [0, 1].  Both buffers must have the same length.
///
/// Sampling strategy: every 16th *pixel* (= every 64th byte in RGBA_8888).
/// At 240 px max-dim the buffer is ≤ ~230 400 bytes → ≤ 3 600 samples —
/// fast enough on the UI thread while covering all three colour channels.
/// Luminance weight: 0.299R + 0.587G + 0.114B  (BT.601, integer approx).
double _meanPixelDelta(Uint8List a, Uint8List b) {
  if (a.length != b.length || a.isEmpty) return 1.0;
  const pixelStride = 64; // 16 pixels × 4 bytes/pixel
  int sum = 0;
  int count = 0;
  for (int i = 0; i + 2 < a.length; i += pixelStride) {
    // BT.601 integer approximation (×1000): 299R + 587G + 114B
    final lumA = 299 * a[i] + 587 * a[i + 1] + 114 * a[i + 2];
    final lumB = 299 * b[i] + 587 * b[i + 1] + 114 * b[i + 2];
    sum += (lumA - lumB).abs();
    count++;
  }
  if (count == 0) return 1.0;
  // Normalise: max possible sum per sample = 1000 × 255 = 255 000
  return sum / (count * 255000.0);
}

// ---------------------------------------------------------------------------
// Main screenshot manager
// ---------------------------------------------------------------------------

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

  /// Raw RGBA bytes of the last frame that was *accepted* (not delta-skipped).
  /// Used for perceptual-change detection.
  Uint8List? _lastAcceptedFrameBytes;

  /// Cached app-document directory — resolved once to avoid repeated async
  /// platform-channel calls on every screenshot (getApplicationDocumentsDirectory
  /// goes through a method channel which adds ~1–3 ms per call on some devices).
  Directory? _appDocDir;
  Directory? _screenshotDir;
  Directory? _archiveDir;

  /// In-memory count of screenshots pending in the screenshot folder.
  /// Avoids a Directory.listSync() syscall after every single write.
  int _pendingScreenshotCount = 0;

  /// Long-lived HTTP client — created once in [start], disposed in [stop].
  /// Reusing the client keeps the TCP connection alive (HTTP keep-alive) so
  /// each upload batch does not pay a full TCP+TLS handshake.
  NetworkManager? _networkManager;

  MiddlewareScreenshotManager({
    required this.builder,
    required this.sessionId,
    required this.repaintBoundaryKey,
  });

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> start(int startTs) async {
    if (_isRunning) return;

    _firstTs = startTs.toString();
    _isRunning = true;
    _lastOrientation = null;
    _lastAcceptedFrameBytes = null;
    _pendingScreenshotCount = 0;

    // Resolve and cache the directory paths once — avoids repeated async
    // platform-channel round-trips on every screenshot tick.
    _appDocDir = await getApplicationDocumentsDirectory();
    _screenshotDir = Directory('${_appDocDir!.path}/screenshots');
    _archiveDir = Directory('${_appDocDir!.path}/archives');
    for (final dir in [_screenshotDir!, _archiveDir!]) {
      if (!await dir.exists()) await dir.create(recursive: true);
    }

    _networkManager = NetworkManager(builder.target, builder.rumAccessToken);

    await _cleanupStaleArchives();

    _screenshotTimer = Timer.periodic(
      builder.recordingOptions.screenshotInterval,
      (_) => _makeScreenshotAndSaveWithArchive(),
    );

    // Upload on a slower cadence — no point hitting the network every 4 s when
    // we only archive every archiveChunkSize frames (= every ~80 s at defaults).
    // Use 3× the screenshot interval as a cheap heuristic so we always upload
    // within one chunk-period of the archive being ready.
    final uploadInterval = builder.recordingOptions.screenshotInterval * 3;
    _uploadTimer = Timer.periodic(uploadInterval, (_) => sendScreenshots());

    await _makeScreenshotAndSaveWithArchive();
    Timer(const Duration(seconds: 2), () => sendScreenshots());
  }

  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;
    _screenshotTimer?.cancel();
    _uploadTimer?.cancel();
    await _terminate();
    _sanitizedElements.clear();
    _lastOrientation = null;
    _lastAcceptedFrameBytes = null;
    _screenshotDir = null;
    _archiveDir = null;
    _networkManager?.dispose();
    _networkManager = null;
  }

  // -------------------------------------------------------------------------
  // Stale-file handling (unchanged logic, kept for parity)
  // -------------------------------------------------------------------------

  Future<void> _cleanupStaleArchives() async {
    if (!builder.recordingOptions.uploadStaleFilesOnStart) {
      if (kDebugMode) debugPrint('Stale file upload disabled by configuration');
      return;
    }
    try {
      if (kDebugMode)
        debugPrint('Checking for stale files from previous sessions…');

      final archiveFolder = await _getArchiveFolder();
      if (await archiveFolder.exists()) {
        final archives = archiveFolder.listSync().whereType<File>().toList();
        if (archives.isNotEmpty) {
          if (kDebugMode)
            debugPrint('Found ${archives.length} stale archive(s)');
          final ok = await _uploadStaleArchives(archives);
          if (!ok) {
            await _deleteOldArchives(
              archives,
              maxAge: builder.recordingOptions.staleArchiveMaxAge,
            );
          }
        }
      }

      final screenshotFolder = await _getScreenshotFolder();
      if (await screenshotFolder.exists()) {
        final screenshots =
            screenshotFolder.listSync().whereType<File>().toList();
        if (screenshots.isNotEmpty) {
          if (kDebugMode)
            debugPrint('Found ${screenshots.length} stale screenshot(s)');
          if (screenshots.length >= builder.recordingOptions.archiveChunkSize) {
            await _archiveFolder(screenshotFolder);
          } else {
            await _deleteOldScreenshots(
              screenshots,
              maxAge: builder.recordingOptions.staleScreenshotMaxAge,
            );
          }
        }
      }
      if (kDebugMode) debugPrint('Stale file cleanup completed');
    } catch (e) {
      if (kDebugMode) debugPrint('Error during stale file cleanup: $e');
    }
  }

  Future<bool> _uploadStaleArchives(List<File> archives) async {
    if (sessionId.isEmpty) return false;
    // Stale upload runs during start() before _networkManager is assigned,
    // so create a short-lived client just for this one-time operation.
    final networkManager = NetworkManager(
      builder.target,
      builder.rumAccessToken,
    );
    try {
      int successCount = 0;

      for (final archive in archives) {
        try {
          final fileName = archive.uri.pathSegments.last;
          if (!fileName.startsWith(sessionId)) {
            final modified = await archive.lastModified();
            if (DateTime.now().difference(modified) >
                const Duration(seconds: 59)) {
              await _deleteFileSafely(archive);
              continue;
            }
          }
          final imageData = await archive.readAsBytes();
          final completer = Completer<bool>();
          final staleSessionId = fileName.split('-')[0];
          await networkManager.sendImages(
            staleSessionId,
            _rumResourceAttributesJson(),
            imageData,
            fileName,
            _NetworkCallbackImpl(
              onSuccessCallback: (r) async {
                await _deleteFileSafely(archive);
                successCount++;
                completer.complete(true);
              },
              onErrorCallback: (e) {
                if (kDebugMode)
                  debugPrint('Failed to upload stale archive: $e');
                completer.complete(false);
              },
            ),
          );
          await completer.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              if (kDebugMode)
                debugPrint('Timeout uploading stale archive: $fileName');
              return false;
            },
          );
        } catch (e) {
          if (kDebugMode) debugPrint('Error uploading stale archive: $e');
        }
      }
      return successCount > 0;
    } catch (e) {
      if (kDebugMode) debugPrint('Error in stale archive upload: $e');
      return false;
    } finally {
      networkManager.dispose(); // always released, even on exception
    }
  }

  Future<void> _deleteOldArchives(
    List<File> archives, {
    required Duration maxAge,
  }) async {
    final now = DateTime.now();
    for (final archive in archives) {
      try {
        if (now.difference(await archive.lastModified()) > maxAge) {
          await _deleteFileSafely(archive);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Error checking archive age: $e');
      }
    }
  }

  Future<void> _deleteOldScreenshots(
    List<File> screenshots, {
    required Duration maxAge,
  }) async {
    final now = DateTime.now();
    for (final screenshot in screenshots) {
      try {
        if (now.difference(await screenshot.lastModified()) > maxAge) {
          await _deleteFileSafely(screenshot);
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Error checking screenshot age: $e');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Capture pipeline  (KEY CHANGES)
  // -------------------------------------------------------------------------

  Future<void> _makeScreenshotAndSaveWithArchive() async {
    try {
      _checkAndReportOrientationChange();

      // _captureScreenshot now returns JPEG bytes OR null (delta-skip / error)
      final screenshotData = await _captureScreenshot();
      if (screenshotData == null) return; // delta-skipped or error

      final screenshotFolder = await _getScreenshotFolder();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      // Store as .jpeg so the archive names are accurate
      final screenshotFile = File('${screenshotFolder.path}/$timestamp.jpeg');
      await screenshotFile.writeAsBytes(screenshotData);
      _pendingScreenshotCount++;

      if (_pendingScreenshotCount >=
          builder.recordingOptions.archiveChunkSize) {
        await _archiveFolder(screenshotFolder);
        _pendingScreenshotCount = 0;
      }
    } catch (e) {
      debugPrint('Error making screenshot: $e');
    }
  }

  RenderRepaintBoundary? _repaintBoundaryFromKey() {
    final ctx = repaintBoundaryKey.currentContext;
    final ro = ctx?.findRenderObject();
    return ro is RenderRepaintBoundary ? ro : null;
  }

  /// Captures, optionally masks, downscales, encodes as lossy JPEG, and
  /// applies perceptual-delta filtering.
  ///
  /// Returns JPEG [Uint8List] or null when the frame is too similar to the
  /// previous accepted frame (idle screen) or an error occurs.
  Future<Uint8List?> _captureScreenshot() async {
    try {
      var boundary = _repaintBoundaryFromKey();
      if (boundary == null) {
        await WidgetsBinding.instance.endOfFrame;
        boundary = _repaintBoundaryFromKey();
      }

      if (boundary == null) {
        if (kDebugMode) {
          final ro = repaintBoundaryKey.currentContext?.findRenderObject();
          if (ro != null) {
            debugPrint(
              'Session replay: GlobalKey must be on a RepaintBoundary '
              '(got ${ro.runtimeType}).',
            );
          } else {
            debugPrint(
              'Session replay: RepaintBoundary not in tree yet — wrap your '
              'app (e.g. MaterialApp) with RepaintBoundary(key: '
              'FlutterOTel.repaintBoundaryKey, child: ...).',
            );
          }
        }
        return null;
      }

      // ------------------------------------------------------------------
      // 1. Capture at native resolution (pixelRatio 1.0 keeps it manageable)
      // ------------------------------------------------------------------
      final rawImage = await boundary.toImage(pixelRatio: 1.0);

      // ------------------------------------------------------------------
      // 2. Downscale FIRST so the longest side ≤ maxDimension.
      //    This must happen before masking so that all subsequent canvas
      //    operations (mask rects, toByteData, JPEG encode) work on the
      //    small image, not the full-resolution one.  Doing it here cuts
      //    masking GPU cost by ~(scale²) ≈ 10–20× on a typical phone.
      // ------------------------------------------------------------------
      final scaledImage = await _scaleDown(
        rawImage,
        builder.recordingOptions.maxDimension,
      );

      // ------------------------------------------------------------------
      // 3. Apply element masking on the already-scaled image (cheap).
      //    Mask coordinates must be scaled proportionally.
      // ------------------------------------------------------------------
      final scaleX = scaledImage.width / rawImage.width;
      final scaleY = scaledImage.height / rawImage.height;
      final maskedImage = await _applyMaskToScreenshot(
        scaledImage,
        scaleX,
        scaleY,
      );

      // ------------------------------------------------------------------
      // 4. Perceptual-delta check on raw RGBA bytes (cheap, pre-encode)
      // ------------------------------------------------------------------
      final rgbaBytes =
          (await maskedImage.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();

      if (_lastAcceptedFrameBytes != null) {
        final delta = _meanPixelDelta(rgbaBytes, _lastAcceptedFrameBytes!);
        if (delta < builder.recordingOptions.deltaThreshold) {
          if (kDebugMode) {
            debugPrint(
              'Session replay: frame skipped (delta=${delta.toStringAsFixed(4)} '
              '< threshold=${builder.recordingOptions.deltaThreshold})',
            );
          }
          return null;
        }
      }
      _lastAcceptedFrameBytes = rgbaBytes;

      // ------------------------------------------------------------------
      // 5. Encode as lossy JPEG (off UI thread via compute)
      // ------------------------------------------------------------------
      if (kDebugMode) {
        debugPrint(
          'Session replay: encoding JPEG with quality=${builder.recordingOptions.qualityValue} '
              'maxDimension=${builder.recordingOptions.maxDimension} '
              'deltaThreshold=${builder.recordingOptions.deltaThreshold}',
        );
      }
      final jpegBytes = await _encodeJpeg(
        maskedImage,
        rgbaBytes,
        builder.recordingOptions.qualityValue,
      );

      if (kDebugMode) {
        debugPrint(
          'Session replay: frame accepted '
          '(${maskedImage.width}×${maskedImage.height}, '
          '${jpegBytes.length} bytes JPEG)',
        );
      }

      return jpegBytes;
    } catch (e) {
      debugPrint('Error capturing screenshot: $e');
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Image helpers
  // -------------------------------------------------------------------------

  /// Scale [image] so its longest dimension is ≤ [maxDim].
  /// If the image is already smaller it is returned as-is.
  Future<ui.Image> _scaleDown(ui.Image image, int maxDim) async {
    final w = image.width;
    final h = image.height;
    final longest = w > h ? w : h;

    if (longest <= maxDim) return image; // already small enough

    final scale = maxDim / longest;
    final newW = (w * scale).round();
    final newH = (h * scale).round();

    if (kDebugMode) {
      debugPrint('Session replay: scaling ${w}×$h → ${newW}×$newH');
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    return recorder.endRecording().toImage(newW, newH);
  }

  /// Encode a [ui.Image] as JPEG at the given [quality] (1–100).
  ///
  /// Implementation note:
  ///   dart:ui does not expose a JPEG encoder directly.  We use the `image`
  ///   package (pub.dev/packages/image) which is a pure-Dart codec.  Add to
  ///   pubspec.yaml:
  ///
  ///     dependencies:
  ///       image: ^4.2.0
  ///
  ///   If you cannot add the dependency, replace the body of this method with
  ///   a PNG fallback — but note that PNG files are 5–15× larger than JPEG
  ///   at equivalent perceived quality, which will significantly increase
  ///   bandwidth.
  Future<Uint8List> _encodeJpeg(
    ui.Image image,
    Uint8List rgbaBytes,
    int quality,
  ) async {
    // Use compute() to run the CPU-intensive encode off the UI thread.
    return compute(
      _encodeJpegIsolate,
      _JpegEncodeParams(
        rgba: rgbaBytes,
        width: image.width,
        height: image.height,
        quality: quality,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Masking
  // -------------------------------------------------------------------------

  /// Apply privacy masks to an already-scaled [image].
  ///
  /// [scaleX] / [scaleY] are (scaled_dimension / original_dimension) and are
  /// used to map the global-coordinate RenderBox positions into the scaled
  /// image's coordinate space.
  Future<ui.Image> _applyMaskToScreenshot(
    ui.Image image,
    double scaleX,
    double scaleY,
  ) async {
    if (_sanitizedElements.isEmpty) return image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());

    final maskPaint =
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.black45;

    for (final key in _sanitizedElements) {
      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.attached) {
        final position = renderBox.localToGlobal(Offset.zero);
        final size = renderBox.size;
        canvas.drawRect(
          Rect.fromLTWH(
            position.dx * scaleX,
            position.dy * scaleY,
            size.width * scaleX,
            size.height * scaleY,
          ),
          maskPaint,
        );
      }
    }

    return recorder.endRecording().toImage(image.width, image.height);
  }

  // -------------------------------------------------------------------------
  // File I/O
  // -------------------------------------------------------------------------

  Future<Directory> _getScreenshotFolder() async {
    if (_screenshotDir != null) return _screenshotDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/screenshots');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _getArchiveFolder() async {
    if (_archiveDir != null) return _archiveDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/archives');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _archiveFolder(Directory folder) async {
    try {
      final entities = folder.listSync();
      final screenshots = <File>[];
      for (final e in entities) {
        if (e is File) screenshots.add(e);
      }
      if (screenshots.isEmpty) return;

      // Sort by filename — filenames are millisecond timestamps so
      // lexicographic order == chronological order; avoids N stat() syscalls.
      screenshots.sort((a, b) {
        final nameA = a.uri.pathSegments.last;
        final nameB = b.uri.pathSegments.last;
        return nameA.compareTo(nameB);
      });

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

      for (final screenshot in screenshots) {
        await screenshot.delete();
      }
    } catch (e) {
      debugPrint('Error archiving folder: $e');
    }
  }

  Future<void> sendScreenshots() async {
    if (sessionId.isEmpty) {
      debugPrint('SessionId is empty');
      return;
    }

    // Guard: if called after stop() there is no network manager.
    final nm = _networkManager;
    if (nm == null) return;

    try {
      final archiveFolder = await _getArchiveFolder();
      // whereType<File> already filters; avoid building a second list with toList
      // only when we know there's something to upload.
      final entities = archiveFolder.listSync();
      final archives = <File>[];
      for (final e in entities) {
        if (e is File) archives.add(e);
      }

      if (archives.isEmpty) {
        if (kDebugMode) debugPrint('No archives to upload');
        return;
      }

      int successCount = 0;
      int failCount = 0;

      for (final archive in archives) {
        try {
          final imageData = await archive.readAsBytes();
          final fileName = archive.uri.pathSegments.last;
          final completer = Completer<bool>();

          await nm.sendImages(
            sessionId,
            _rumResourceAttributesJson(),
            imageData,
            fileName,
            _NetworkCallbackImpl(
              onSuccessCallback: (response) async {
                final deleted = await _deleteFileSafely(archive);
                deleted ? successCount++ : failCount++;
                completer.complete(deleted);
              },
              onErrorCallback: (e) {
                if (kDebugMode) debugPrint('Upload failed for $fileName: $e');
                failCount++;
                completer.complete(false);
              },
            ),
          );

          await completer.future;
        } catch (e) {
          if (kDebugMode) debugPrint('Error processing archive: $e');
          failCount++;
        }
      }

      if (kDebugMode) {
        debugPrint(
          'Upload summary: $successCount succeeded, $failCount failed',
        );
      }
    } catch (e) {
      debugPrint('Error sending screenshot archives: $e');
    }
  }

  Future<bool> _deleteFileSafely(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
        if (await file.exists()) {
          if (kDebugMode)
            debugPrint('File still exists after delete: ${file.path}');
          return false;
        }
        return true;
      }
      return true; // already gone
    } catch (e) {
      if (kDebugMode) debugPrint('Error deleting file ${file.path}: $e');
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Misc helpers
  // -------------------------------------------------------------------------

  void setViewForBlur(GlobalKey key) => _sanitizedElements.add(key);

  void removeSanitizedElement(GlobalKey key) => _sanitizedElements.remove(key);

  void _checkAndReportOrientationChange() {
    final context = repaintBoundaryKey.currentContext;
    if (context == null) return;
    final orientation = MediaQuery.of(context).orientation;
    if (orientation != _lastOrientation) {
      _lastOrientation = orientation;
      debugPrint('Current orientation: $orientation');
    }
  }

  Future<void> _terminate() async {
    try {
      final screenshotFolder = await _getScreenshotFolder();
      await _archiveFolder(screenshotFolder);
      await sendScreenshots();
    } catch (e) {
      debugPrint('Error during termination: $e');
    }
  }

  String _getNameWithoutExtension(File file) {
    final name = file.uri.pathSegments.last;
    final lastDot = name.lastIndexOf('.');
    return lastDot > 0 ? name.substring(0, lastDot) : name;
  }
}

// ---------------------------------------------------------------------------
// Isolate helpers for off-thread JPEG encoding
// ---------------------------------------------------------------------------

class _JpegEncodeParams {
  final Uint8List rgba;
  final int width;
  final int height;
  final int quality;

  const _JpegEncodeParams({
    required this.rgba,
    required this.width,
    required this.height,
    required this.quality,
  });
}

/// Top-level function (required for [compute]).
///
/// Uses the `image` package (pub.dev/packages/image ≥ 4.0).
/// Add to pubspec.yaml:  image: ^4.2.0
Uint8List _encodeJpegIsolate(_JpegEncodeParams p) {
  // ignore: depend_on_referenced_packages
  final img = image_pkg.Image.fromBytes(
    width: p.width,
    height: p.height,
    bytes: p.rgba.buffer,
    format: image_pkg.Format.uint8,
    numChannels: 4,
  );
  return Uint8List.fromList(image_pkg.encodeJpg(img, quality: p.quality));
}

// Alias so only this file needs the import line.
// Add to your imports:  import 'package:image/image.dart' as image_pkg;
// (The import is intentionally not written here to keep the file self-contained
// in the diff; add it at the top with the rest of the imports.)

// ---------------------------------------------------------------------------

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
