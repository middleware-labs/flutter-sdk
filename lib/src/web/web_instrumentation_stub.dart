// Licensed under the Apache License, Version 2.0

// Non-web builds: browser instrumentation does not exist.

import '../common/network_capture.dart';
import 'web_instrumentation_options.dart';

bool isBotTraffic() => false;

String? pagePath() => null;

Map<String, Object> browserResourceAttributes() => const {};

void enable(
  WebInstrumentationOptions options, {
  required List<Pattern> ignoreUrls,
  required NetworkCapture networkCapture,
}) {}

void disable() {}
