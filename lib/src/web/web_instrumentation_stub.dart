// Licensed under the Apache License, Version 2.0

// Non-web builds: browser instrumentation does not exist.

import 'web_instrumentation_options.dart';

bool isBotTraffic() => false;

Map<String, Object> browserResourceAttributes() => const {};

void enable(
  WebInstrumentationOptions options, {
  required List<Pattern> ignoreUrls,
}) {}

void disable() {}
