// Licensed under the Apache License, Version 2.0

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Gzips through the browser's CompressionStream, which runs off the main
/// thread. Returns null on browsers without it (Safari < 16.4).
Future<Uint8List?> gzipBytes(Uint8List bytes) async {
  if (!web.window.has('CompressionStream')) return null;
  try {
    final stream = web.CompressionStream('gzip');
    final writer = stream.writable.getWriter();
    // Not awaited: the readable side is drained below, and awaiting the write
    // first would deadlock once the stream's internal queue fills.
    writer.write(bytes.toJS);
    writer.close();
    final buffer = await web.Response(stream.readable).arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } catch (_) {
    return null;
  }
}
