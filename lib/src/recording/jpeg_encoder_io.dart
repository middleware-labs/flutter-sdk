// Licensed under the Apache License, Version 2.0

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image_pkg;

/// Native JPEG encoder.
///
/// Runs the CPU-intensive `image` package encode inside a real background
/// isolate via [compute] so the UI thread is never blocked. (On native
/// platforms `compute` spawns a true isolate, unlike web.)
Future<Uint8List> encodeJpeg({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
}) {
  return compute(
    _encodeJpegIsolate,
    _JpegEncodeParams(
      rgba: rgba,
      width: width,
      height: height,
      quality: quality,
    ),
  );
}

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
Uint8List _encodeJpegIsolate(_JpegEncodeParams p) {
  final img = image_pkg.Image.fromBytes(
    width: p.width,
    height: p.height,
    bytes: p.rgba.buffer,
    format: image_pkg.Format.uint8,
    numChannels: 4,
  );
  return Uint8List.fromList(image_pkg.encodeJpg(img, quality: p.quality));
}
