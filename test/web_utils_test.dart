// Licensed under the Apache License, Version 2.0

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:middleware_flutter_opentelemetry/src/web/web_utils.dart';

void main() {
  group('span names', () {
    test('drop query and fragment', () {
      expect(
        computeHttpSpanName('get', 'https://api.example.com/users/1?token=x#f'),
        'GET api.example.com/users/1',
      );
    });

    test('resolve relative URLs against a base', () {
      expect(
        computeHttpSpanName('POST', '/v2/items', base: 'https://app.test/a/'),
        'POST app.test/v2/items',
      );
    });

    test('fall back to the method alone', () {
      expect(computeHttpSpanName(null, null), 'HTTP');
    });
  });

  group('trace header propagation', () {
    test('same origin always propagates', () {
      expect(
        shouldPropagateTraceHeaders(
          'https://app.test/api',
          'https://app.test',
          const [],
        ),
        isTrue,
      );
    });

    test('cross origin only when targeted', () {
      expect(
        shouldPropagateTraceHeaders(
          'https://api.other.com/x',
          'https://app.test',
          const [],
        ),
        isFalse,
      );
      expect(
        shouldPropagateTraceHeaders(
          'https://api.other.com/x',
          'https://app.test',
          [RegExp(r'api\.other\.com')],
        ),
        isTrue,
      );
    });

    test('SDK exports are ignored', () {
      expect(
        isUrlIgnored('https://x.middleware.io/v1/traces', defaultIgnoredUrls),
        isTrue,
      );
      expect(
        isUrlIgnored('https://x.middleware.io/api/data', defaultIgnoredUrls),
        isFalse,
      );
      expect(
        isUrlIgnored(
          'http://localhost:8090/packages/characters/src/extensions.dart.lib.js',
          defaultIgnoredUrls,
        ),
        isTrue,
      );
      expect(
        isUrlIgnored('https://app.test/main.dart.js', defaultIgnoredUrls),
        isFalse,
      );
    });
  });

  group('resource classification', () {
    test('types', () {
      expect(computeResourceType('script', 'https://a/main.dart.js'), 'js');
      expect(computeResourceType('fetch', 'https://a/x.js'), 'fetch');
      expect(computeResourceType('img', 'https://a/pic'), 'image');
      expect(computeResourceType('other', 'https://a/f.woff2'), 'font');
      expect(computeResourceType('other', 'https://a/manifest.json'), 'other');
    });

    test('provider', () {
      expect(
        computeResourceProviderType('https://app.test/a', 'app.test'),
        'first-party',
      );
      expect(
        computeResourceProviderType('https://cdn.x.com/a', 'app.test'),
        'cdn',
      );
      expect(
        computeResourceProviderType('https://www.gstatic.com/a', 'app.test'),
        'other',
      );
    });
  });

  group('resource timing attributes', () {
    test('visible timings produce phases', () {
      final attrs = resourceTimingAttributes(
        const ResourceTimingData(
          startTime: 10,
          fetchStart: 10,
          domainLookupStart: 11,
          domainLookupEnd: 13,
          connectStart: 13,
          secureConnectionStart: 14,
          connectEnd: 20,
          requestStart: 21,
          responseStart: 40,
          responseEnd: 50,
          transferSize: 500,
          decodedBodySize: 1000,
        ),
      );
      expect(attrs['resource.duration'], 29);
      expect(attrs['resource.dns.duration'], 2);
      expect(attrs['resource.connect.duration'], 7);
      expect(attrs['resource.ssl.duration'], 6);
      expect(attrs['resource.first_byte.duration'], 19);
      expect(attrs['resource.download.duration'], 10);
      expect(attrs['resource.redirect.duration'], 0);
      expect(attrs.containsKey('resource.timing_visible'), isFalse);
    });

    test('hidden cross-origin timings are not turned into durations', () {
      final attrs = resourceTimingAttributes(
        const ResourceTimingData(
          startTime: 100,
          fetchStart: 100,
          responseEnd: 180,
        ),
      );
      expect(attrs['resource.timing_visible'], isFalse);
      expect(attrs['resource.duration'], 80);
      expect(attrs.containsKey('resource.download.duration'), isFalse);
    });

    test('cache hit and withheld status', () {
      final r = const ResourceTimingData(transferSize: 0, decodedBodySize: 10);
      expect(resourceTimingAttributes(r)['resource.cache_hit'], isTrue);
      expect(resourceStatusAttributes(r), {'resource.status_code': 0});
      expect(
        resourceStatusAttributes(const ResourceTimingData(responseStatus: 404)),
        {'resource.status_code': 404, 'http.response.status_code': 404},
      );
    });
  });

  group('browser detection', () {
    const chrome =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

    test('browser info matches the browser SDK', () {
      final info = browserInfo(chrome);
      expect(info.name, 'Chrome');
      expect(info.version, '140.0.0.0');
      expect(browserInfo('Mozilla/5.0 Edg/120.0.1').name, 'Edge');
    });

    test('os', () {
      expect(browserOs('MacIntel', chrome), 'Mac OS');
      expect(
        browserOs('Linux armv8l', 'Mozilla/5.0 (Linux; Android 14)'),
        'Android',
      );
      expect(
        browserOs('', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'),
        'Windows',
      );
      expect(browserOs('', chrome), 'Mac OS');
    });

    test('bots', () {
      expect(isBotUserAgent(chrome), isFalse);
      expect(isBotUserAgent('Mozilla/5.0 HeadlessChrome/140.0'), isTrue);
      expect(isBotUserAgent('Googlebot/2.1'), isTrue);
    });

    test('extension noise is ignored', () {
      expect(shouldIgnoreMessage('at chrome-extension://abc/x.js:1:1'), isTrue);
      expect(shouldIgnoreMessage('TypeError: x is undefined'), isFalse);
    });
  });

  group('web vitals', () {
    test('snake case keys', () {
      expect(toSnakeCase('largestShiftTarget'), 'largest_shift_target');
      expect(toSnakeCase('firstByteToFCP'), 'first_byte_to_fcp');
    });

    test('ratings', () {
      expect(webVitalRating('LCP', 2000), 'good');
      expect(webVitalRating('LCP', 3000), 'needs-improvement');
      expect(webVitalRating('CLS', 0.3), 'poor');
    });

    test('CLS keeps the worst session window', () {
      final cls = ClsAccumulator();
      cls.add(0.1, 0);
      cls.add(0.1, 500); // same window: 0.2
      cls.add(0.05, 3000); // new window: 0.05
      expect(cls.value, closeTo(0.2, 1e-9));
      cls.add(0.3, 3500); // window 0.35
      expect(cls.value, closeTo(0.35, 1e-9));
      expect(cls.largestShiftValue, 0.3);
    });

    test('INP skips one outlier per 50 interactions', () {
      final inp = InpAccumulator();
      for (var i = 1; i <= 60; i++) {
        inp.add(
          InpInteraction(
            interactionId: i,
            duration: i == 60 ? 900 : 100 + i.toDouble(),
            startTime: 0,
            processingStart: 0,
            processingEnd: 0,
            name: 'pointerup',
          ),
        );
      }
      expect(inp.worst!.duration, 159); // the 900ms outlier is skipped
    });
  });

  test('rage click needs 4 close, quick clicks', () {
    final detector = RageClickDetector();
    final t = DateTime(2026);
    expect(detector.isRageClick(10, 10, now: t), isFalse);
    expect(
      detector.isRageClick(
        12,
        10,
        now: t.add(const Duration(milliseconds: 100)),
      ),
      isFalse,
    );
    expect(
      detector.isRageClick(
        14,
        10,
        now: t.add(const Duration(milliseconds: 200)),
      ),
      isFalse,
    );
    expect(
      detector.isRageClick(
        16,
        10,
        now: t.add(const Duration(milliseconds: 300)),
      ),
      isTrue,
    );
    // A far-away click starts over.
    expect(
      detector.isRageClick(
        500,
        500,
        now: t.add(const Duration(milliseconds: 400)),
      ),
      isFalse,
    );
  });

  test('interaction attribution window', () {
    InteractionContext.clear();
    final t = DateTime(2026);
    InteractionContext.setActiveInteraction(
      't1',
      's1',
      name: 'click on x',
      startedAt: t,
    );
    expect(
      InteractionContext.attributesAt(t.add(const Duration(milliseconds: 500))),
      {
        'interaction.trace_id': 't1',
        'interaction.span_id': 's1',
        'interaction.name': 'click on x',
      },
    );
    expect(
      InteractionContext.attributesAt(t.add(const Duration(seconds: 2))),
      isEmpty,
    );
    InteractionContext.clear();
  });

  group('JS stack parsing', () {
    test('V8', () {
      final frames = parseJsStack(
        'Error: boom\n'
        '    at handler (https://app.test/main.dart.js:10:5)\n'
        '    at https://app.test/:39:34',
      );
      expect(frames, hasLength(2));
      expect(frames[0]['functionName'], 'handler');
      expect(frames[0]['fileName'], 'https://app.test/main.dart.js');
      expect(frames[0]['lineNumber'], 10);
      expect(frames[0]['columnNumber'], 5);
      expect(frames[1].containsKey('functionName'), isFalse);
      expect(frames[1]['lineNumber'], 39);
    });

    test('Firefox / Safari', () {
      final frames = parseJsStack(
        'handler@https://app.test/main.dart.js:10:5\n@https://app.test/:39:34',
      );
      expect(frames[0]['functionName'], 'handler');
      expect(frames[0]['lineNumber'], 10);
      expect(frames[1]['fileName'], 'https://app.test/');
    });

    test('stack details are JSON-safe', () {
      final details = exceptionStackFrames(
        parseJsStack('Error\n    at f (https://a/x.js:1:2)'),
      );
      expect(jsonDecode(safeJson(details)), [
        {
          'exception.line': 1,
          'exception.function_name': 'f',
          'exception.function_body': '    at f (https://a/x.js:1:2)',
          'exception.column_number': 2,
          'exception.file': 'https://a/x.js',
        },
      ]);
    });
  });
}
