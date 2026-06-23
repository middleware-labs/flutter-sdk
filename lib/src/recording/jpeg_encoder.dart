// Licensed under the Apache License, Version 2.0

import 'dart:typed_data';

// Platform-specific JPEG encoder.
//
// Native (VM): the `image` package runs inside a real background isolate via
// `compute`, keeping the CPU-heavy encode off the UI thread.
//
// Web: `compute` has NO background isolate (Flutter web is single-threaded), so
// the pure-Dart encoder would block the UI on every frame. Instead we use the
// browser's native, asynchronous, off-main-thread JPEG encoder via an
// OffscreenCanvas/`<canvas>.toBlob('image/jpeg', q)`.
import 'jpeg_encoder_io.dart'
    if (dart.library.html) 'jpeg_encoder_web.dart'
    if (dart.library.js_interop) 'jpeg_encoder_web.dart'
    as impl;

/// Encodes raw RGBA pixels ([rgba], length must be `width * height * 4`) as a
/// lossy JPEG at [quality] (1–100).
///
/// The work is kept off the UI thread on every platform: a background isolate
/// on native, the browser's native encoder on web.
Future<Uint8List> encodeJpeg({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
}) {
  return impl.encodeJpeg(
    rgba: rgba,
    width: width,
    height: height,
    quality: quality,
  );
}
