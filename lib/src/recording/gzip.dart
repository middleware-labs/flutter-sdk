// Licensed under the Apache License, Version 2.0

import 'dart:typed_data';

// Platform-specific gzip.
//
// Native (VM): dart:io's zlib codec.
//
// Web: a pure-Dart deflate would run on the UI thread (Flutter web is
// single-threaded), so we use the browser's asynchronous CompressionStream.
import 'gzip_io.dart'
    if (dart.library.html) 'gzip_web.dart'
    if (dart.library.js_interop) 'gzip_web.dart'
    as impl;

/// Gzips [bytes], or returns null when compression is unavailable or fails —
/// the caller then sends the body uncompressed.
Future<Uint8List?> gzipBytes(Uint8List bytes) => impl.gzipBytes(bytes);
