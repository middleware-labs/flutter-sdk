// Licensed under the Apache License, Version 2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:middleware_flutter_opentelemetry/src/util/sdk_version.dart';

void main() {
  test('middlewareFlutterSdkVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)!;
    expect(
      middlewareFlutterSdkVersion,
      version.group(1),
      reason: 'bump lib/src/util/sdk_version.dart with the pubspec',
    );
  });
}
