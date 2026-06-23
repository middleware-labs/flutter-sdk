// Licensed under the Apache License, Version 2.0

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web JPEG encoder.
///
/// Flutter web has no background isolates, so `compute` would run the pure-Dart
/// `image` encoder synchronously on the UI isolate and jank the app on every
/// captured frame. Instead this hands the pixels to the browser's built-in
/// image codec, which encodes natively and off the main thread:
///
/// - Preferred: [web.OffscreenCanvas] + `convertToBlob` (fully off-main-thread).
/// - Fallback: a detached `<canvas>` + `toBlob` for browsers without
///   OffscreenCanvas support.
Future<Uint8List> encodeJpeg({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
}) async {
  final q = (quality.clamp(1, 100)) / 100.0;
  final imageData = _imageData(rgba, width, height);

  try {
    return await _encodeWithOffscreenCanvas(imageData, width, height, q);
  } catch (_) {
    // OffscreenCanvas unsupported or failed — fall back to a <canvas> element.
    return _encodeWithCanvasElement(imageData, width, height, q);
  }
}

web.ImageData _imageData(Uint8List rgba, int width, int height) {
  // View (no copy) over the RGBA buffer to avoid a ~width*height*4 byte
  // allocation on every captured frame; putImageData reads it synchronously, so
  // the view never outlives the source buffer.
  final clamped = Uint8ClampedList.view(
    rgba.buffer,
    rgba.offsetInBytes,
    rgba.length,
  );
  // package:web's ImageData has a polymorphic ctor: (data, sw, [sh|settings]).
  // The 3rd positional is typed JSAny, so the height must be passed as a JS num.
  return web.ImageData(clamped.toJS, width, height.toJS);
}

Future<Uint8List> _encodeWithOffscreenCanvas(
  web.ImageData imageData,
  int width,
  int height,
  double quality,
) async {
  final canvas = web.OffscreenCanvas(width, height);
  final ctx =
      canvas.getContext('2d') as web.OffscreenCanvasRenderingContext2D?;
  if (ctx == null) {
    throw StateError('OffscreenCanvas 2D context unavailable');
  }
  ctx.putImageData(imageData, 0, 0);
  final blob =
      await canvas
          .convertToBlob(
            web.ImageEncodeOptions(type: 'image/jpeg', quality: quality),
          )
          .toDart;
  return _blobToBytes(blob);
}

Future<Uint8List> _encodeWithCanvasElement(
  web.ImageData imageData,
  int width,
  int height,
  double quality,
) {
  final canvas =
      web.document.createElement('canvas') as web.HTMLCanvasElement
        ..width = width
        ..height = height;
  final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D?;
  if (ctx == null) {
    return Future.error(StateError('Canvas 2D context unavailable'));
  }
  ctx.putImageData(imageData, 0, 0);

  final completer = Completer<Uint8List>();
  void onBlob(web.Blob? blob) {
    if (blob == null) {
      completer.completeError(StateError('Canvas toBlob returned null'));
      return;
    }
    _blobToBytes(blob).then(completer.complete, onError: completer.completeError);
  }

  canvas.toBlob(onBlob.toJS, 'image/jpeg', quality.toJS);
  return completer.future;
}

Future<Uint8List> _blobToBytes(web.Blob blob) async {
  final buffer = await blob.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}
