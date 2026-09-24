// Licensed under the Apache License, Version 2.0

import 'dart:io';
import 'dart:typed_data';

Future<Uint8List?> gzipBytes(Uint8List bytes) async {
  try {
    return Uint8List.fromList(gzip.encode(bytes));
  } catch (_) {
    return null;
  }
}
