import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';

import 'jpeg_encoder.dart' as jpeg;
import 'rrweb_events.dart';
import 'rrweb_exporter.dart';

/// Resource attributes stamped on every replay batch, read live from the
/// tracer provider so runtime updates (session rotation, `recording`) are
/// reflected. [sessionId] wins over the resource's own `session.id` because a
/// batch can still hold events from the session that just rotated out.
Map<String, String> _rumResourceAttributes(String sessionId) {
  final attributes = <String, String>{};
  try {
    final provider = OTel.tracerProvider();
    provider.ensureResourceIsSet();
    for (final attribute in provider.resource?.attributes.toList() ?? []) {
      attributes[attribute.key] = attribute.value.toString();
    }
  } catch (_) {
    // resource not available yet; the batch still carries the session id
  }
  attributes['session.id'] = sessionId;
  return attributes;
}

/// Capture frequency of the NATIVE v3 recorder (Android/iOS).
enum NativeRecordingFrequency { low, standard, high }

/// Image quality of the NATIVE v3 recorder (Android/iOS).
enum NativeRecordingQuality { low, standard, high }

/// Recording options configuration
class RecordingOptions {
  /// How often a frame is captured. Default 1 s, the native SDKs' default
  /// frequency; frames are skipped anyway while nothing is rendered.
  final Duration screenshotInterval;

  /// JPEG quality 1–100. Default 50, the native SDKs' "standard" quality
  /// (Android and iOS use 25 / 50 / 75 for low / standard / high).
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
  /// Default 640, the native SDKs' short edge. Frames are captured at up to
  /// the device pixel ratio to reach it, and never upscaled beyond that.
  final int minShortSidePx;

  @Deprecated('No effect: frames are streamed as rrweb events, not archived.')
  final int archiveChunkSize;

  @Deprecated('No effect: frames are streamed as rrweb events, not archived.')
  final Duration staleArchiveMaxAge;

  @Deprecated('No effect: frames are streamed as rrweb events, not archived.')
  final Duration staleScreenshotMaxAge;

  @Deprecated('No effect: frames are streamed as rrweb events, not archived.')
  final bool uploadStaleFilesOnStart;

  /// NATIVE v3 recorder options (Android/iOS only). Null values use the
  /// native SDK defaults. The fields above configure the pure-Dart recorder
  /// (web / v3 opt-out) and do not affect the native recorder.
  final NativeRecordingFrequency? frequency;
  final NativeRecordingQuality? quality;

  /// Mask all text in the NATIVE v3 recording. NOTE: has no effect on
  /// Flutter widget content (the native mask collector sees one opaque
  /// FlutterView); it only applies to native views layered in the app.
  final bool? maskAllTextInputs;

  /// Mask image content in the NATIVE v3 recording (native views only).
  final bool? maskAllImages;

  const RecordingOptions({
    this.screenshotInterval = const Duration(seconds: 1),
    this.qualityValue = 50,
    this.minShortSidePx = 640,
    this.archiveChunkSize = 10,
    this.staleArchiveMaxAge = const Duration(seconds: 59),
    this.staleScreenshotMaxAge = const Duration(seconds: 59),
    this.uploadStaleFilesOnStart = true,
    this.frequency,
    this.quality,
    this.maskAllTextInputs,
    this.maskAllImages,
  });

  /// Shape sent over the native bridge; null when nothing is configured.
  Map<String, Object?>? toNativeMap() {
    final map = <String, Object?>{
      if (frequency != null) 'frequency': frequency!.name,
      if (quality != null) 'quality': quality!.name,
      if (maskAllTextInputs != null) 'maskAllTextInputs': maskAllTextInputs,
      if (maskAllImages != null) 'maskAllImages': maskAllImages,
    };
    return map.isEmpty ? null : map;
  }
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

// ---------------------------------------------------------------------------
// Main screenshot manager
// ---------------------------------------------------------------------------
//
// The Dart recorder, used where the native SDKs don't record (web, desktop).
// Emits the same rrweb stream as the native v3 recorders: a Meta +
// FullSnapshot pair per "epoch", an img-src mutation per changed frame, touch
// interactions and screen-name custom events, exported by [RRWebExporter].
//
// An epoch restarts when the recorder starts, the session id rotates, the
// viewport size changes, or the app becomes visible again.
//
// - `stopped` → [_stopped]: set before tearing down timers / network so late
//   async capture callbacks can drop work safely.
// - `captureInFlight` → [_captureInFlight]: periodic capture skips if the prior
//   capture is still running. Dart is single-threaded on the event loop so a
//   plain bool is safe here.

class MiddlewareScreenshotManager with WidgetsBindingObserver {
  final MiddlewareBuilder builder;
  String _sessionId;
  final GlobalKey repaintBoundaryKey;

  /// Optional hook (e.g. [SessionManager.checkIdleTime]) invoked at the start
  /// of each screenshot tick while recording is active.
  final void Function()? onRecordingTick;

  String get sessionId => _sessionId;

  void updateSessionId(String value) {
    if (value == _sessionId) return;
    // session rotated: the old session's stream is complete, start a new
    // epoch under the new id
    _sessionId = value;
    _resetEpoch();
  }

  Timer? _screenshotTimer;

  // FIX #5 — Changed from List<GlobalKey> to a Set to prevent duplicate
  // entries and make remove O(1). Dead-key pruning happens lazily in
  // _applyMaskToScreenshot (keys whose context is null are skipped and
  // collected for removal after iteration — same pattern as Java's
  // collectMaskRects dead-WeakReference pruning).
  final Set<GlobalKey> _sanitizedElements = {};

  bool _isRunning = false;

  /// Whether the recorder is currently capturing.
  bool get isRunning => _isRunning;

  /// Set in [stop] before timers are cancelled so late async capture work can
  /// bail out safely.
  bool _stopped = false;

  /// If a capture is still running, the next periodic tick is skipped instead
  /// of queueing another.
  bool _captureInFlight = false;

  /// Whether Flutter rendered a frame since the last capture. Nothing on
  /// screen can have changed otherwise, so the tick skips the capture, the
  /// GPU readback and the JPEG encode (identical frames used to be dropped
  /// only after all three).
  bool _renderedSinceCapture = true;
  bool _watchingFrames = false;

  void _watchFrames() {
    if (_watchingFrames) return;
    _watchingFrames = true;
    SchedulerBinding.instance.addPostFrameCallback(_onFrameRendered);
  }

  // Re-arms itself for the next frame; registering doesn't schedule one, so
  // an idle app costs nothing.
  void _onFrameRendered(Duration _) {
    _renderedSinceCapture = true;
    if (_isRunning) {
      SchedulerBinding.instance.addPostFrameCallback(_onFrameRendered);
    } else {
      _watchingFrames = false;
    }
  }

  /// Last [_screenshotTick] future — [stop] awaits this before the final flush.
  Future<void>? _ongoingCapture;

  /// Created in [start], shut down (final flush) in [stop].
  RRWebExporter? _exporter;

  // Epoch state
  bool _sentMeta = false;
  int _lastMetaWidth = -1;
  int _lastMetaHeight = -1;
  String? _lastFrameDataUri;
  String? _lastScreenName;

  /// Current route name, pushed by the navigator observer.
  String? _screenName;

  /// Whether the app was hidden/paused since the last frame.
  bool _wasHidden = false;

  MiddlewareScreenshotManager({
    required this.builder,
    required String sessionId,
    required this.repaintBoundaryKey,
    this.onRecordingTick,
  }) : _sessionId = sessionId;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> start() async {
    if (_isRunning) return;

    _stopped = false;
    _isRunning = true;
    _resetEpoch();

    _exporter = RRWebExporter(
      target: builder.target,
      token: builder.rumAccessToken,
      resourceAttributes: _rumResourceAttributes,
    );

    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
    _watchFrames();

    _screenshotTimer = Timer.periodic(
      builder.recordingOptions.screenshotInterval,
      (_) {
        unawaited(_screenshotTick());
      },
    );
    unawaited(_screenshotTick());
  }

  Future<void> stop() async {
    if (!_isRunning) return;
    // Must be visible to any in-flight async capture before we tear down the
    // exporter.
    _stopped = true;
    _isRunning = false;
    _screenshotTimer?.cancel();
    _screenshotTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);

    try {
      await (_ongoingCapture ?? Future<void>.value());
      await _exporter?.shutdown();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Session replay: error during shutdown: $e');
      }
    }

    _exporter = null;
    _sanitizedElements.clear();
    _maskPatternImage?.dispose();
    _maskPatternImage = null;
    _stopped = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // going away (tab hidden / app backgrounded): get buffered events out
        // while we still can
        _wasHidden = true;
        unawaited(_exporter?.flush());
      case AppLifecycleState.resumed:
        if (_wasHidden && _sentMeta) {
          // returning to the foreground: force a fresh Meta + FullSnapshot
          _resetEpoch();
        }
        _wasHidden = false;
      default:
        break;
    }
  }

  /// Sets the screen name used for the replay timeline and the Meta href.
  void setScreenName(String name) => _screenName = name;

  void _resetEpoch() {
    _sentMeta = false;
    _lastMetaWidth = -1;
    _lastMetaHeight = -1;
    _lastFrameDataUri = null;
    _lastScreenName = null;
    _renderedSinceCapture = true;
  }

  // -------------------------------------------------------------------------
  // Capture pipeline
  // -------------------------------------------------------------------------

  /// One capture tick: capture, encode, emit.
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
      return;
    }
    _captureInFlight = true;
    try {
      onRecordingTick?.call();
      if (_stopped) {
        return;
      }
      if (!_renderedSinceCapture && _lastFrameDataUri != null) {
        return; // nothing rendered since the last frame we shipped
      }
      // Cleared before capturing: a frame rendered meanwhile marks it again.
      _renderedSinceCapture = false;

      final frame = await _captureScreenshot();
      if (_stopped || frame == null) {
        return;
      }
      emitFrame(frame.jpeg, frame.width, frame.height);
    } catch (e) {
      debugPrint('Error making screenshot: $e');
    } finally {
      _captureInFlight = false;
    }
  }

  @visibleForTesting
  set exporterForTest(RRWebExporter exporter) => _exporter = exporter;

  /// Turns a captured frame into rrweb events: Meta + FullSnapshot when a new
  /// epoch starts, otherwise an img-src mutation (skipped if unchanged).
  @visibleForTesting
  void emitFrame(Uint8List jpegBytes, int width, int height) {
    final exporter = _exporter;
    if (exporter == null || _sessionId.isEmpty) return;

    final needsMeta =
        !_sentMeta || width != _lastMetaWidth || height != _lastMetaHeight;
    final dataUri = 'data:image/jpeg;base64,${base64Encode(jpegBytes)}';
    if (!needsMeta && dataUri == _lastFrameDataUri) {
      return; // identical frame, nothing to ship
    }

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final screenName = _screenName;
    if (needsMeta) {
      exporter.enqueue(
        RRWebEvents.meta(_href(screenName), width, height, timestamp),
        _sessionId,
      );
      exporter.enqueue(
        RRWebEvents.fullSnapshot(dataUri, width, height, timestamp),
        _sessionId,
      );
      _sentMeta = true;
      _lastMetaWidth = width;
      _lastMetaHeight = height;
    } else {
      exporter.enqueue(
        RRWebEvents.frameMutation(dataUri, timestamp),
        _sessionId,
      );
    }
    _lastFrameDataUri = dataUri;

    if (screenName != null && screenName != _lastScreenName) {
      _lastScreenName = screenName;
      exporter.enqueue(
        RRWebEvents.screenCustom(screenName, timestamp),
        _sessionId,
      );
    }
  }

  /// The page URL on web (so the player's jump-to-path works); a synthetic
  /// app URL elsewhere, like the native SDKs' `android-app://` hrefs.
  String _href(String? screenName) =>
      kIsWeb ? Uri.base.toString() : 'flutter-app://app/${screenName ?? ''}';

  void _onPointerEvent(PointerEvent event) {
    if (!_isRunning || !_sentMeta) {
      return; // touches before the first FullSnapshot are unplayable
    }
    final int interactionType;
    if (event is PointerDownEvent) {
      interactionType = RRWebEvents.mouseInteractionTouchStart;
    } else if (event is PointerUpEvent) {
      interactionType = RRWebEvents.mouseInteractionTouchEnd;
    } else {
      return;
    }
    final boundary = _repaintBoundaryFromKey();
    final position =
        boundary != null && boundary.attached
            ? boundary.globalToLocal(event.position)
            : event.position;
    _exporter?.enqueue(
      RRWebEvents.touch(
        interactionType,
        position.dx.round(),
        position.dy.round(),
        DateTime.now().millisecondsSinceEpoch,
      ),
      _sessionId,
    );
  }

  RenderRepaintBoundary? _repaintBoundaryFromKey() {
    final ctx = repaintBoundaryKey.currentContext;
    final ro = ctx?.findRenderObject();
    return ro is RenderRepaintBoundary ? ro : null;
  }

  /// What a frame is captured from: the app's
  /// `RepaintBoundary(key: FlutterOTel.repaintBoundaryKey)` when it has one,
  /// otherwise the whole root view, so replay needs no app changes.
  ///
  /// [size] is logical pixels, the size the frame is replayed at; [capture]
  /// renders at that size.
  ({
    Size size,
    double devicePixelRatio,
    Future<ui.Image> Function(double pixelRatio) capture,
  })?
  _captureTarget() {
    final views = RendererBinding.instance.renderViews;
    final viewDpr =
        views.isEmpty ? 1.0 : views.first.configuration.devicePixelRatio;
    final boundary = _repaintBoundaryFromKey();
    if (boundary != null && boundary.hasSize) {
      return (
        size: boundary.size,
        devicePixelRatio: viewDpr,
        capture: (pixelRatio) => boundary.toImage(pixelRatio: pixelRatio),
      );
    }
    if (views.isEmpty) return null;
    final view = views.first;
    // The root view is always a repaint boundary, so its layer is the
    // OffsetLayer (a TransformLayer scaling logical to physical pixels) that
    // RenderRepaintBoundary.toImage would use. `debugLayer` is null in
    // release builds, hence the protected getter.
    // ignore: invalid_use_of_protected_member
    final layer = view.layer;
    if (layer is! OffsetLayer || view.size.isEmpty) {
      return null;
    }
    final dpr = view.configuration.devicePixelRatio;
    final size = view.size;
    return (
      size: size,
      devicePixelRatio: dpr,
      // Bounds are in the layer's parent space (physical pixels); dividing
      // by dpr undoes the layer's own dpr transform.
      capture:
          (pixelRatio) => layer.toImage(
            Offset.zero & (size * dpr),
            pixelRatio: pixelRatio / dpr,
          ),
    );
  }

  /// Captures, optionally masks, downscales and encodes as lossy JPEG.
  ///
  /// Returns the JPEG with the boundary's logical size (the size the frame is
  /// replayed at), or null when an error occurs.
  Future<({Uint8List jpeg, int width, int height})?>
  _captureScreenshot() async {
    // ui.Image instances hold native/GPU-backed pixel buffers that are NOT
    // reclaimed by ordinary Dart GC promptly — they must be disposed explicitly
    // or they accumulate (a full-window capture every tick is large, especially
    // on web). These are disposed exactly once in the finally block below; note
    // that _scaleToShortSide / _applyMaskToScreenshot may return the *same*
    // instance they were given (when they are no-ops), so we dedup by identity.
    ui.Image? rawImage;
    ui.Image? scaledImage;
    ui.Image? maskedImage;
    try {
      var target = _captureTarget();
      if (target == null) {
        await WidgetsBinding.instance.endOfFrame;
        if (_stopped) {
          return null;
        }
        target = _captureTarget();
      }

      if (target == null) {
        if (OTelLog.isDebug()) {
          OTelLog.debug(
            'Session replay: nothing rendered yet, skipping frame.',
          );
        }
        return null;
      }

      if (_stopped) {
        return null;
      }

      // ------------------------------------------------------------------
      // 1. Capture at native resolution (pixelRatio 1.0 keeps it manageable)
      // ------------------------------------------------------------------
      // Render just enough pixels for the short side to reach
      // minShortSidePx (the replay's resolution), up to the screen's real
      // resolution. 1x logical pixels made text blurry on HiDPI screens.
      final shortSide = math.min(target.size.width, target.size.height);
      final pixelRatio =
          shortSide <= 0
              ? 1.0
              : (builder.recordingOptions.minShortSidePx / shortSide)
                  .clamp(1.0, math.max(1.0, target.devicePixelRatio))
                  .toDouble();
      rawImage = await target.capture(pixelRatio);

      if (_stopped) {
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
      scaledImage = await _scaleToShortSide(
        rawImage,
        builder.recordingOptions.minShortSidePx,
      );

      // ------------------------------------------------------------------
      // 3. Apply element masking on the already-scaled image (cheap).
      //    Mask coordinates must be scaled proportionally.
      // ------------------------------------------------------------------
      final scaleX = scaledImage.width / rawImage.width;
      final scaleY = scaledImage.height / rawImage.height;
      maskedImage = await _applyMaskToScreenshot(scaledImage, scaleX, scaleY);

      if (_stopped) {
        return null;
      }

      // ------------------------------------------------------------------
      // 4. Encode as lossy JPEG (off UI thread: background isolate on native,
      //    browser-native canvas encoder on web).
      // ------------------------------------------------------------------
      // Per-frame diagnostics: only with SDK debug logging on, since at two
      // frames a second they flood the console of every debug build.
      if (OTelLog.isDebug()) {
        OTelLog.debug(
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

      final jpegBytes = await jpeg.encodeJpeg(
        rgba: rgbaBytes,
        width: maskedImage.width,
        height: maskedImage.height,
        quality: builder.recordingOptions.qualityValue,
      );

      if (OTelLog.isDebug()) {
        OTelLog.debug(
          'Session replay: frame accepted '
          '(${maskedImage.width}×${maskedImage.height}, '
          '${jpegBytes.length} bytes JPEG)',
        );
      }

      return (
        jpeg: jpegBytes,
        width: target.size.width.round(),
        height: target.size.height.round(),
      );
    } catch (e) {
      debugPrint('Error capturing screenshot: $e');
      return null;
    } finally {
      for (final img in <ui.Image?>{rawImage, scaledImage, maskedImage}) {
        img?.dispose();
      }
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

    if (OTelLog.isDebug()) {
      OTelLog.debug('Session replay: scaling $w×$h → $newW×$newH');
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
      canvas.drawLine(Offset(i, -1), Offset(i + size, size + 1), stripePaint);
    }

    // Rotate 90° around centre and draw the same stripes (cross-hatch)
    canvas.save();
    canvas.translate(size / 2.0, size / 2.0);
    canvas.rotate(90 * 3.141592653589793 / 180);
    canvas.translate(-size / 2.0, -size / 2.0);
    for (double i = -size.toDouble(); i < size * 2; i += step) {
      canvas.drawLine(Offset(i, -1), Offset(i + size, size + 1), stripePaint);
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
  // Misc helpers
  // -------------------------------------------------------------------------

  void setViewForBlur(GlobalKey key) => _sanitizedElements.add(key);

  void removeSanitizedElement(GlobalKey key) => _sanitizedElements.remove(key);
}

// ---------------------------------------------------------------------------
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
