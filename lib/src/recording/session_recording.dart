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
//  New defaults: JPEG q=10, 320 min-short-side (parity with Android),
//                4 s interval, chunk=10
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

/// Archive files are named `{sessionId}-{lastTs}.tar.gz` with a hyphen between
/// the id and the timestamp (session id has no hyphens).
String _sessionIdFromArchiveFileName(String fileName, String fallbackSessionId) {
  if (!fileName.endsWith('.tar.gz')) return fallbackSessionId;
  final base = fileName.substring(0, fileName.length - 7);
  final dash = base.indexOf('-');
  if (dash <= 0) return fallbackSessionId;
  return base.substring(0, dash);
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
  /// reducing [minShortSidePx].
  final int qualityValue;

  /// FIX #1 — Renamed from maxDimension.
  ///
  /// The *shortest* side is scaled UP/DOWN to exactly this many pixels,
  /// matching Android's `MIN_RESOLUTION_PX` logic in the Java SDK:
  ///
  ///   portrait:  newW = minShortSidePx,  newH = newW / aspect
  ///   landscape: newH = minShortSidePx,  newW = newH * aspect
  ///
  /// This keeps the same visual density on both orientations and is consistent
  /// with how the Middleware backend expects session-replay frames to be sized.
  final int minShortSidePx;

  /// Number of frames to bundle per archive before uploading.
  final int archiveChunkSize;

  final Duration staleArchiveMaxAge;
  final Duration staleScreenshotMaxAge;
  final bool uploadStaleFilesOnStart;

  const RecordingOptions({
    this.screenshotInterval = const Duration(milliseconds: 500),
    this.qualityValue = 10,
    this.minShortSidePx = 320,
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
// Main screenshot manager
// ---------------------------------------------------------------------------
//
// Lifecycle mirrors the Android `MiddlewareScreenshotManager` replay v2:
// - `stopped` → [_stopped]: set before tearing down timers / network so late
//   async capture callbacks can drop work safely.
// - `captureInFlight` → [_captureInFlight]: periodic capture skips if the prior
//   pipeline (through serialized disk write) is still running.
//   NOTE: Dart is single-threaded on the event loop so a plain bool is safe
//   here — there is no race between the timer callback and the capture
//   completion because both run on the same isolate's microtask/event queue.
//   compute() isolates never mutate this field directly; they only return a
//   value via Future which is awaited back on the main isolate.
// - Single-thread IO → [_serializedIoTail]: archives, file writes, and uploads
//   are chained so they never overlap (like `ioExecutor` + FIFO queue).
// - Terminal flush → [_terminateFlush]: last archive + send before recycling
//   the HTTP client (like `terminateFlush` on the IO executor).

class MiddlewareScreenshotManager {
  String _firstTs = '';
  String _lastTs = '';
  final MiddlewareBuilder builder;
  String _sessionId;
  final GlobalKey repaintBoundaryKey;

  /// Optional hook (e.g. [SessionManager.checkIdleTime]) invoked at the start
  /// of each screenshot tick while recording is active.
  final void Function()? onRecordingTick;

  String get sessionId => _sessionId;

  void updateSessionId(String value) => _sessionId = value;

  Timer? _screenshotTimer;
  Timer? _uploadTimer;

  // FIX #5 — Changed from List<GlobalKey> to a Set to prevent duplicate
  // entries and make remove O(1). Dead-key pruning happens lazily in
  // _applyMaskToScreenshot (keys whose context is null are skipped and
  // collected for removal after iteration — same pattern as Java's
  // collectMaskRects dead-WeakReference pruning).
  final Set<GlobalKey> _sanitizedElements = {};

  Orientation? _lastOrientation;
  bool _isRunning = false;

  /// Set in [stop] before timers are cancelled so late async capture work can
  /// bail out safely (parity with Android `stopped`).
  bool _stopped = false;

  /// If a capture pipeline is still running, the next periodic tick is skipped
  /// instead of queueing another (parity with Android `captureInFlight`).
  /// Safe as a plain bool — see class-level comment above.
  bool _captureInFlight = false;

  /// Last [_screenshotTick] future — [stop] awaits this before terminal flush.
  Future<void>? _ongoingCapture;

  /// Single FIFO chain for disk + archive + upload so work never overlaps
  /// (parity with Android single-thread `ioExecutor`).
  Future<void> _serializedIoTail = Future<void>.value();

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
    required String sessionId,
    required this.repaintBoundaryKey,
    this.onRecordingTick,
  }) : _sessionId = sessionId;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> start(int startTs) async {
    if (_isRunning) return;

    _stopped = false;
    _firstTs = startTs.toString();
    _isRunning = true;
    _lastOrientation = null;
    _pendingScreenshotCount = 0;
    _serializedIoTail = Future<void>.value();

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
      (_) {
        unawaited(_screenshotTick());
      },
    );

    // FIX #9 — Upload on the same cadence as screenshots, matching Java's
    // `scheduleWithFixedDelay(...intervalMillis, intervalMillis, ...)`.
    // Previously this was screenshotInterval × 3, which meant archives could
    // sit on disk for up to 3× the interval before being sent.
    _uploadTimer = Timer.periodic(
      builder.recordingOptions.screenshotInterval,
      (_) {
        unawaited(_enqueueSerializedIo(sendScreenshots));
      },
    );

    unawaited(_screenshotTick());
    Timer(const Duration(seconds: 2), () {
      unawaited(_enqueueSerializedIo(sendScreenshots));
    });
  }

  Future<void> stop() async {
    if (!_isRunning) return;
    // Must be visible to any in-flight PixelCopy / async capture before we tear
    // down executors or the network client (Android parity).
    _stopped = true;
    _isRunning = false;
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    _uploadTimer?.cancel();
    _uploadTimer = null;

    try {
      await (_ongoingCapture ?? Future<void>.value());
      await _enqueueSerializedIo(_terminateFlush, ignoreStopped: true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Session replay: error during shutdown pipeline: $e');
      }
    }

    _sanitizedElements.clear();
    _lastOrientation = null;
    _screenshotDir = null;
    _archiveDir = null;
    _networkManager?.dispose();
    _networkManager = null;
    _stopped = false;
  }

  /// Append [job] after prior serialized IO work. Used for writes, archives,
  /// uploads, and the terminal flush so those never run concurrently.
  Future<void> _enqueueSerializedIo(
    Future<void> Function() job, {
    bool ignoreStopped = false,
  }) {
    final completer = Completer<void>();
    _serializedIoTail = _serializedIoTail
        .then((_) async {
          try {
            if (_stopped && !ignoreStopped) {
              return;
            }
            await job();
          } catch (e, st) {
            if (kDebugMode) {
              debugPrint('Session replay: serialized IO error: $e\n$st');
            }
          } finally {
            if (!completer.isCompleted) {
              completer.complete();
            }
          }
        })
        .catchError((Object e, StackTrace st) {
          if (kDebugMode) {
            debugPrint('Session replay: serialized IO chain error: $e\n$st');
          }
          if (!completer.isCompleted) {
            completer.complete();
          }
        });
    return completer.future;
  }

  Future<void> _terminateFlush() async {
    try {
      final screenshotFolder = await _getScreenshotFolder();
      await _archiveFolder(screenshotFolder);
      await sendScreenshots();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Session replay: error during termination flush: $e');
      }
    }
  }

  // -------------------------------------------------------------------------
  // Stale-file handling
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

          // FIX #3 — Stale archives by definition come from *previous* sessions.
          // The old code skipped archives whose filename DID NOT start with
          // sessionId, which is the wrong predicate — stale archives will never
          // start with the current session id because a new session id is
          // generated on each app launch.
          //
          // Correct behaviour (matching Java): attempt to upload every stale
          // archive regardless of which session it belongs to. If the file is
          // too old and the upload fails, fall through to age-based deletion.
          // The uploadSessionId extracted below ensures each batch is attributed
          // to the correct session on the backend.
          final modified = await archive.lastModified();
          if (DateTime.now().difference(modified) >
              builder.recordingOptions.staleArchiveMaxAge) {
            await _deleteFileSafely(archive);
            continue;
          }

          final imageData = await archive.readAsBytes();
          final completer = Completer<bool>();
          final staleSessionId = _sessionIdFromArchiveFileName(
            fileName,
            sessionId,
          );
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
  // Capture pipeline
  // -------------------------------------------------------------------------

  /// One capture tick: UI-thread capture, then serialized disk / archive work.
  Future<void> _screenshotTick() {
    final run = _runScreenshotTick();
    _ongoingCapture = run;
    return run.whenComplete(() {
      if (identical(_ongoingCapture, run)) {
        _ongoingCapture = null;
      }
    });
  }

  Future<void> _runScreenshotTick() async {
    if (!_isRunning || _stopped) {
      return;
    }
    if (_captureInFlight) {
      if (kDebugMode) {
        debugPrint(
          'Session replay: screenshot skipped — previous capture still in flight',
        );
      }
      return;
    }
    _captureInFlight = true;
    try {
      onRecordingTick?.call();
      if (_stopped) {
        return;
      }
      _checkAndReportOrientationChange();

      final screenshotData = await _captureScreenshot();
      if (_stopped || screenshotData == null) {
        return;
      }

      await _enqueueSerializedIo(() async {
        if (_stopped) {
          return;
        }
        final screenshotFolder = await _getScreenshotFolder();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final screenshotFile = File('${screenshotFolder.path}/$timestamp.jpeg');
        await screenshotFile.writeAsBytes(screenshotData);
        _pendingScreenshotCount++;

        if (_pendingScreenshotCount >=
            builder.recordingOptions.archiveChunkSize) {
          await _archiveFolder(screenshotFolder);
          _pendingScreenshotCount = 0;
        }
      });
    } catch (e) {
      debugPrint('Error making screenshot: $e');
    } finally {
      _captureInFlight = false;
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
  /// Returns JPEG [Uint8List] or null when an error occurs.
  Future<Uint8List?> _captureScreenshot() async {
    try {
      var boundary = _repaintBoundaryFromKey();
      if (boundary == null) {
        await WidgetsBinding.instance.endOfFrame;
        if (_stopped) {
          return null;
        }
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

      if (_stopped) {
        return null;
      }

      // ------------------------------------------------------------------
      // 1. Capture at native resolution (pixelRatio 1.0 keeps it manageable)
      // ------------------------------------------------------------------
      final rawImage = await boundary.toImage(pixelRatio: 1.0);

      if (_stopped) {
        rawImage.dispose();
        return null;
      }

      // ------------------------------------------------------------------
      // 2. FIX #1 — Scale so the SHORT side == minShortSidePx, matching the
      //    Android SDK's MIN_RESOLUTION_PX logic:
      //
      //      portrait:  newW = minShortSidePx, newH = newW / aspect
      //      landscape: newH = minShortSidePx, newW = newH * aspect
      //
      //    Previously Flutter capped the LONGEST side which produced smaller
      //    images than Android on portrait screens and inconsistent replay
      //    frame sizes across platforms.
      // ------------------------------------------------------------------
      final scaledImage = await _scaleToShortSide(
        rawImage,
        builder.recordingOptions.minShortSidePx,
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

      if (_stopped) {
        return null;
      }

      // ------------------------------------------------------------------
      // 4. Encode as lossy JPEG (off UI thread via compute)
      // ------------------------------------------------------------------
      if (kDebugMode) {
        debugPrint(
          'Session replay: encoding JPEG with quality=${builder.recordingOptions.qualityValue} '
          'minShortSidePx=${builder.recordingOptions.minShortSidePx}',
        );
      }
      final rgbaBytes =
          (await maskedImage.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();

      if (_stopped) {
        return null;
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

  /// FIX #1 — Scale [image] so its SHORT side == [minShortSidePx], matching
  /// Android's `MIN_RESOLUTION_PX` behaviour exactly.
  ///
  /// Portrait (w < h): set newW = minShortSidePx, derive newH from aspect.
  /// Landscape/square (w >= h): set newH = minShortSidePx, derive newW.
  ///
  /// If the image is already at or below the target short-side it is returned
  /// as-is (no upscaling, matching Android's `Math.max(MIN_RESOLUTION_PX, 1)`
  /// guard which keeps the image unchanged when it is already small).
  Future<ui.Image> _scaleToShortSide(ui.Image image, int minShortSidePx) async {
    final w = image.width;
    final h = image.height;
    final isPortrait = w < h;
    final shortSide = isPortrait ? w : h;

    // Already at or smaller than the target — return as-is (no upscaling).
    if (shortSide <= minShortSidePx) return image;

    final int newW;
    final int newH;
    if (isPortrait) {
      newW = minShortSidePx;
      newH = (newW * h / w).round().clamp(1, 1 << 15);
    } else {
      newH = minShortSidePx;
      newW = (newH * w / h).round().clamp(1, 1 << 15);
    }

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
  /// Uses the `image` package (pub.dev/packages/image ≥ 4.0) via compute()
  /// to keep the CPU-intensive encode off the UI thread.
  ///
  ///   dependencies:
  ///     image: ^4.2.0
  Future<Uint8List> _encodeJpeg(
    ui.Image image,
    Uint8List rgbaBytes,
    int quality,
  ) async {
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

  /// FIX #6 — Mask fill is now a cross-striped pattern bitmap matching the
  /// Android SDK's `createCrossStripedPatternBitmap()`, instead of the
  /// previous solid `Colors.black45`.
  ///
  /// The pattern is rendered once via a [ui.Picture] and cached as a
  /// [ui.Image] so it is only built on the first call.
  ui.Image? _maskPatternImage;

  Future<ui.Image> _getMaskPatternImage() async {
    if (_maskPatternImage != null) return _maskPatternImage!;

    const int size = 80;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // White background
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
      Paint()..color = Colors.white,
    );

    // Dark-grey diagonal stripes (forward direction)
    final stripePaint =
        Paint()
          ..color = Colors.grey.shade700
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.0;

    const double step = 25.0;
    for (double i = -size.toDouble(); i < size * 2; i += step) {
      canvas.drawLine(
        Offset(i, -1),
        Offset(i + size, size + 1),
        stripePaint,
      );
    }

    // Rotate 90° around centre and draw the same stripes (cross-hatch)
    canvas.save();
    canvas.translate(size / 2.0, size / 2.0);
    canvas.rotate(90 * 3.141592653589793 / 180);
    canvas.translate(-size / 2.0, -size / 2.0);
    for (double i = -size.toDouble(); i < size * 2; i += step) {
      canvas.drawLine(
        Offset(i, -1),
        Offset(i + size, size + 1),
        stripePaint,
      );
    }
    canvas.restore();

    final picture = recorder.endRecording();
    _maskPatternImage = await picture.toImage(size, size);
    return _maskPatternImage!;
  }

  /// Apply privacy masks to an already-scaled [image].
  ///
  /// FIX #5 — Dead keys (whose context is null or whose RenderBox is detached)
  /// are collected during iteration and removed after the loop, matching Java's
  /// `collectMaskRects` dead-WeakReference pruning.
  ///
  /// FIX #6 — Uses the cross-striped pattern instead of solid black.
  ///
  /// [scaleX] / [scaleY] map the global-coordinate RenderBox positions into
  /// the scaled image's coordinate space.
  Future<ui.Image> _applyMaskToScreenshot(
    ui.Image image,
    double scaleX,
    double scaleY,
  ) async {
    if (_sanitizedElements.isEmpty) return image;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(image, Offset.zero, Paint());

    final patternImage = await _getMaskPatternImage();
    final maskPaint =
        Paint()
          ..shader = ImageShader(
            patternImage,
            TileMode.repeated,
            TileMode.repeated,
            Matrix4.identity().storage,
          );

    // FIX #5 — Collect dead keys for post-iteration removal.
    final deadKeys = <GlobalKey>[];

    for (final key in _sanitizedElements) {
      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.attached) {
        deadKeys.add(key);
        continue;
      }
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

    // Prune dead references so the set does not grow unboundedly over a long
    // session where widgets are added/removed via setViewForBlur.
    for (final key in deadKeys) {
      _sanitizedElements.remove(key);
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

      // FIX #7 — Set lastTs once from the last (most-recent) file after sort,
      // matching Java's `lastTs = getNameWithoutExtension(screenshots[last])`.
      // Previously lastTs was overwritten in the loop body on every iteration;
      // the end result was identical but the intent was unclear.
      _lastTs = _getNameWithoutExtension(screenshots.last);

      final archive = Archive();
      for (final screenshot in screenshots) {
        final filename =
            '${_firstTs}_1_${_getNameWithoutExtension(screenshot)}.jpeg';
        // FIX #7 — Read file into Uint8List once. The archive library requires
        // the full bytes for in-memory archiving; streaming is not exposed by
        // the `archive` package's Archive/ArchiveFile API.  The IO cost is
        // acceptable given the small frame sizes (< 30 KB each at default
        // quality settings).
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

  /// FIX #2 — Upload all pending archives concurrently (fire-and-forget per
  /// archive), matching the Java SDK which submits every archive to the network
  /// without awaiting each one before starting the next.
  ///
  /// Each archive's delete-on-success / log-on-error callback still runs
  /// individually. We collect all Futures and await them together so the
  /// serialized-IO chain does not release until all uploads for this batch
  /// have settled.
  Future<void> sendScreenshots() async {
    if (sessionId.isEmpty) {
      debugPrint('SessionId is empty');
      return;
    }

    final nm = _networkManager;
    if (nm == null) return;

    try {
      final archiveFolder = await _getArchiveFolder();
      final entities = archiveFolder.listSync();
      final archives = <File>[];
      for (final e in entities) {
        if (e is File) archives.add(e);
      }

      if (archives.isEmpty) {
        if (kDebugMode) debugPrint('No archives to upload');
        return;
      }

      // Launch all uploads concurrently — one Future per archive.
      final uploadFutures = <Future<bool>>[];
      for (final archive in archives) {
        uploadFutures.add(_uploadArchive(nm, archive));
      }

      final results = await Future.wait(uploadFutures);
      final successCount = results.where((r) => r).length;
      final failCount = results.length - successCount;

      if (kDebugMode) {
        debugPrint(
          'Upload summary: $successCount succeeded, $failCount failed',
        );
      }
    } catch (e) {
      debugPrint('Error sending screenshot archives: $e');
    }
  }

  /// Uploads a single [archive] and returns true on success.
  Future<bool> _uploadArchive(NetworkManager nm, File archive) async {
    try {
      final imageData = await archive.readAsBytes();
      final fileName = archive.uri.pathSegments.last;
      final completer = Completer<bool>();

      final uploadSessionId = _sessionIdFromArchiveFileName(
        fileName,
        sessionId,
      );
      await nm.sendImages(
        uploadSessionId,
        _rumResourceAttributesJson(),
        imageData,
        fileName,
        _NetworkCallbackImpl(
          onSuccessCallback: (response) async {
            final deleted = await _deleteFileSafely(archive);
            completer.complete(deleted);
          },
          onErrorCallback: (e) {
            if (kDebugMode)
              debugPrint('Upload failed for $fileName: $e');
            completer.complete(false);
          },
        ),
      );
      return await completer.future;
    } catch (e) {
      if (kDebugMode) debugPrint('Error processing archive: $e');
      return false;
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
