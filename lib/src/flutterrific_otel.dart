// Licensed under the Apache License, Version 2.0

import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    as sdk;
import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart';
import 'package:middleware_flutter_opentelemetry/middleware_flutter_opentelemetry.dart';
import 'package:middleware_flutter_opentelemetry/src/factory/otel_flutter_factory.dart';
import 'package:middleware_flutter_opentelemetry/src/recording/session_recording.dart';
import 'package:uuid/uuid.dart';

typedef CommonAttributesFunction = Attributes Function();

/// A span processor that injects common attributes into every span.
class CommonAttributeSpanProcessor implements SimpleSpanProcessor {
  final SpanProcessor delegate;
  final CommonAttributesFunction commonAttributesFn;

  CommonAttributeSpanProcessor({
    required this.delegate,
    required this.commonAttributesFn,
  });

  @override
  Future<void> onStart(Span span, Context? parentContext) async {
    final attrs = commonAttributesFn.call();
    span.addAttributes(attrs);
    delegate.onStart(span, parentContext);
  }

  @override
  Future<void> onEnd(Span span) {
    return delegate.onEnd(span);
  }

  @override
  Future<void> shutdown() {
    return delegate.shutdown();
  }

  @override
  Future<void> forceFlush() {
    return delegate.forceFlush();
  }

  @override
  Future<void> onNameUpdate(Span span, String newName) {
    return delegate.onNameUpdate(span, newName);
  }
}

/// Main entry point for Middleware Flutter OpenTelemetry SDK.
///
/// This class provides a simple API for adding OpenTelemetry tracing
/// to Flutter applications with minimal configuration.
///
/// FlutterOTel relies on OTel from middleware_dart_opentelemetry. For custom
/// OTel code such as making custom spans, tracers or spanProcessors, use
/// the [OTel] class from Middleware.
/// can use the complete OTel SDK class from Middleware.
class FlutterOTel {
  static const defaultServiceName = "@dart/middleware-flutter-opentelemetry";
  static const defaultServiceVersion = "0.1.0";
  static const middlewareEndpoint = "https://app.middleware.io";

  static OTelLifecycleObserver? _lifecycleObserver;

  /// Lifecycle observer for automatic app lifecycle tracing
  static OTelLifecycleObserver get lifecycleObserver {
    return _lifecycleObserver ??= OTelLifecycleObserver();
  }

  /// Interaction tracker for user interaction tracing
  static OTelInteractionTracker? _interactionTracker;

  /// Lifecycle observer for automatic app lifecycle tracing
  static OTelInteractionTracker get interactionTracker {
    return _interactionTracker ??= OTelInteractionTracker();
  }

  static final Map<String, sdk.Span> _activeSpans = <String, sdk.Span>{};

  // Defaults to the serviceName
  static String? _appName;

  /// A function to return attributes to include in all traces, called when
  /// spans are created but the UITracer.  This is a good place to include
  /// value that change over time (as opposed to resource attributes, which
  /// do not change) to correlate traces.  Consider adding values for
  /// UserSemantics userId, userRole and userSession.
  static CommonAttributesFunction? commonAttributesFunction;

  /// Created during initialize, this id is common throughout all traces until
  /// the app is closed.
  static String? appLaunchId;

  /// An id for the latest app lifecycle
  static Uint8List? currentAppLifecycleId;

  static OTelNavigatorObserver? _routeObserver;

  /// Add this to the observers in GoRouter or the NavigatorObserver in the
  /// MaterialApp if not using GoRouter
  static OTelNavigatorObserver get routeObserver {
    if (_routeObserver == null) {
      throw StateError('FlutterOTel.initialize() must be called first.');
    }
    return _routeObserver!;
  }

  /// Lifecycle observer for automatic app lifecycle tracing
  static String get appName {
    if (_appName == null) {
      throw StateError('FlutterOTel.initialize() must be called first.');
    }
    return _appName!;
  }

  /// Must be called before using any other FlutterOTel or OTel methods.
  /// Sets up the global default TracerProvider and it's tracers.
  /// Adds the lifecycleObserver to observer and trace app lifecycle events.
  /// [appName] defaults to serviceName.
  /// [endpoint] is a url, defaulting to http://app.middleware.io, the default port
  /// for the default gRPC protocol on a localhost.
  /// [serviceName] SHOULD uniquely identify the instrumentation scope, such as
  /// the instrumentation library (e.g. @dart/opentelemetry_api),
  /// package, module or class name.
  /// [serviceVersion] defaults to the matching OTel spec version
  /// plus a release version of this library, currently  1.11.0.0
  /// [tracerName] the name of the default tracer for the global Tracer provider
  /// it defaults to 'middleware' but should be set to something app-specific.
  /// [tracerVersion] the version of the default tracer for the global Tracer
  /// provider.  Defaults to null.
  /// [resourceAttributes] Resource attributes added to [TracerProvider]s.
  /// Resource attributes are set once and do not change during a process.
  /// The tenant_id and the resources from [detectPlatformResources] are merged
  /// with [resourceAttributes] with [resourceAttributes] taking priority.
  /// The values must be valid Attribute types (String, bool, int, double, or
  /// List\<String>, List\<bool>, List\<int> or List\<double>).
  /// [traceAttributesFunction]
  /// [usesGoRouter] whether the instrumented app uses GoRouter,
  /// defaults to true, makes GoRouter spans faster and more reliable.
  /// [middlewareAccountKey] for middleware.io users, the middlewareio AccountKey
  /// [spanProcessor] The SpanProcessor to add to the defaultTracerProvider.
  /// If null, the following batch span processor and OTLP gRPC exporter is
  /// created and added to the default TracerProvider
  /// ```
  //       final exporter = OtlpGrpcSpanExporter(
  //         OtlpGrpcExporterConfig(
  //           endpoint: endpoint,
  //           insecure: true,
  //         ),
  //       );
  //       final spanProcessor = BatchSpanProcessor(
  //         exporter,
  //         BatchSpanProcessorConfig(
  //           maxQueueSize: 2048,
  //           scheduleDelay: Duration(seconds: 1),
  //           maxExportBatchSize: 512,
  //         ),
  //       );
  //       sdk.OTel.tracerProvider().addSpanProcessor(spanProcessor);
  /// ```
  /// [sampler] is the sampling strategy to use. Defaults to AlwaysOnSampler.
  /// [spanKind] is the default SpanKind to use. The OTel default is
  /// SpanKind.internal.  This defaults the SpanKind to SpanKind.client.
  /// Note that Middleware OTel defaults to SpanKind.server
  /// [detectPlatformResources] whether or not to detect platform resources,
  /// Defaults to true.  If set to false, as of this release, there's no need
  /// to await this initialize call, though this may change a future release.
  ///   os.type: 'android|ios|macos|linux|windows' (from Platform.isXXX)
  ///   os.version: io.Platform.operatingSystemVersion
  ///   process.executable.name: io.Platform.executable
  ///   process.command_line: io.Platform.executableArguments.join(' ')
  ///   process.runtime.name: dart
  ///   process.runtime.version: io.Platform.version
  ///   process.num_threads: io.Platform.numberOfProcessors.toString()
  ///   host.name: io.Platform.localHostname,
  ///   host.arch: io.Platform.localHostname,
  ///   host.processors: io.Platform.numberOfProcessors,
  ///   host.os.name: io.Platform.operatingSystem,
  ///   host.locale: io.Platform.localeName,

  /// Under the hood this sets a variety of intelligent defaults:
  // Points to the OTel spec's default gRPC endpoint on the localhost: https://localhost:4317, which isn't
  // very useful for mobile, except for development with localhost redirected.
  // TODO - doc using the collector locally for dev with simulator/emulator.
  // Providing a value for `dartasticApiKey` will point the endpoint to: https://otel.dartastic.io:4317
  // - It gets computes an OTel [Resource](https://opentelemetry.io/docs/specs/otel/resource/sdk/) for the device
  //   so all traces can be tied back to the device.
  //   The Resource includes:
  //   For all platforms :
  //   os.type: 'android|ios|macos|linux|windows' (from Platform.isXXX)
  //   os.version: io.Platform.operatingSystemVersion
  //   process.executable.name: io.Platform.executable
  //   process.command_line: io.Platform.executableArguments.join(' ')
  //   process.runtime.name: dart
  //   process.runtime.version: io.Platform.version
  //   process.num_threads: io.Platform.numberOfProcessors.toString()
  //   host.name: io.Platform.localHostname,
  //   host.arch: io.Platform.localHostname,
  //   host.processors: io.Platform.numberOfProcessors,
  //   host.os.name: io.Platform.operatingSystem,
  //   host.locale: io.Platform.localeName,
  //
  //   For Flutter web:
  //   browser.language: html.window.navigator.language
  //   browser.platform: html.window.navigator.platform
  //   browser.user_agent: html.window.navigator.userAgent
  //   browser.mobile: html.window.navigator.userAgent.contains('Mobile').toString()
  //   browser.languages: html.window.navigator.languages?.join(',')
  //   browser.vendor: html.window.navigator.vendor,
  //   Environmental variables and `--dart-define`'s (TODO - doc)
  // TODO - function to get the app session key
  // TODO - function to get device id
  // TODO - function to use for devs including device_info_plus to call it
  static MiddlewareScreenshotManager? _screenshotManager;
  static final GlobalKey _repaintBoundaryKey = GlobalKey();

  static MiddlewareScreenshotManager? get screenshotManager =>
      _screenshotManager;

  /// Get the repaint boundary key for wrapping your app
  static GlobalKey get repaintBoundaryKey => _repaintBoundaryKey;
  static bool isRecording = false;

  // and return attributes
  static Future<void> initialize({
    String? appName,
    String? endpoint,
    bool secure = true,
    String serviceName = defaultServiceName,
    String? serviceVersion = defaultServiceVersion,
    String? tracerName,
    String? tracerVersion,
    Attributes? resourceAttributes,
    CommonAttributesFunction? commonAttributesFunction,
    sdk.SpanProcessor? spanProcessor,
    sdk.Sampler? sampler,
    SpanKind spanKind = SpanKind.client,
    String? middlewareAccountKey,
    Duration? flushTracesInterval = const Duration(seconds: 30),
    bool detectPlatformResources = true,
    // Metrics configuration
    MetricExporter? metricExporter,
    MetricReader? metricReader,
    bool enableMetrics = true,
  }) async {
    _appName = appName ?? serviceName;
    FlutterOTel.commonAttributesFunction = commonAttributesFunction;
    if (endpoint == null) {
      // OTel environment variables come first
      final envEndpoint = const String.fromEnvironment(
        'OTEL_EXPORTER_OTLP_ENDPOINT',
      );
      if (envEndpoint.isNotEmpty) {
        endpoint = envEndpoint;
        if (OTelLog.isDebug()) {
          OTelLog.debug(
            'Using endpoint from OTEL_EXPORTER_OTLP_ENDPOINT: $endpoint',
          );
        }
      } else if (middlewareAccountKey != null &&
          middlewareAccountKey.isNotEmpty) {
        endpoint = middlewareEndpoint;
        if (OTelLog.isDebug()) {
          OTelLog.debug('Using default Middleware endpoint : $endpoint');
        }
      } else {
        endpoint = OTelFactory.defaultEndpoint;
        if (OTelLog.isDebug()) {
          OTelLog.debug(
            'Using endpoint from OTelFactory.defaultEndpoint: $endpoint',
          );
        }
      }
    }

    if (OTelLog.isDebug()) OTelLog.debug('Using endpoint: $endpoint');

    resourceAttributes ??= sdk.OTel.attributes();
    appLaunchId = Uuid().v4().replaceAll('-', '');
    if (middlewareAccountKey != null && middlewareAccountKey.isNotEmpty) {
      try {
        final builder = MiddlewareBuilder(
          target: endpoint,
          rumAccessToken: middlewareAccountKey,
          recordingOptions: const RecordingOptions(
            screenshotInterval: Duration(seconds: 2),
            qualityValue: 80,
            minResolution: 320,
            archiveChunkSize: 10,
          ),
        );

        _screenshotManager = MiddlewareScreenshotManager(
          builder: builder,
          sessionId: appLaunchId!,
          repaintBoundaryKey: _repaintBoundaryKey,
        );

        if (kDebugMode) {
          debugPrint(
            'Screenshot manager initialized for session: $appLaunchId',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Failed to initialize screenshot manager: $e');
        }
      }
    }
    resourceAttributes = resourceAttributes.copyWithAttributes(
      <String, Object>{
        AppLifecycleSemantics.appLaunchId.key: appLaunchId!,
        'session.id': appLaunchId!,
        'mw.rum': 'true',
        'os': kIsWeb ? 'web' : Platform.operatingSystem,
        'recording': _screenshotManager == null ? '0' : '1',
      }.toAttributes(),
    );

    // Create platform-specific exporters if not provided
    if (spanProcessor == null) {
      sdk.SpanExporter exporter;
      // Web platform must use HTTP
      if (OTelLog.isDebug()) {
        OTelLog.debug('Creating HTTP span exporter for web platform');
      }
      if (middlewareAccountKey != null && middlewareAccountKey.isNotEmpty) {
        exporter = OtlpHttpSpanExporter(
          OtlpHttpExporterConfig(
            endpoint: endpoint,
            compression: false,
            headers: {
              "Authorization": middlewareAccountKey,
              // Web doesn't handle compression well
              "Content-Type": "application/json",
              "Access-Control-Allow-Origin": "*",
              "Origin": "sdk.middleware.io",
            },
          ),
        );
      } else {
        exporter = OtlpHttpSpanExporter(
          OtlpHttpExporterConfig(endpoint: endpoint, compression: false),
        );
      }

      final baseProcessor = sdk.BatchSpanProcessor(
        exporter,
        const BatchSpanProcessorConfig(
          maxQueueSize: 2048,
          scheduleDelay: Duration(seconds: 1),
          maxExportBatchSize: 512,
        ),
      );

      // Wrap with common attribute injector
      spanProcessor = CommonAttributeSpanProcessor(
        delegate: baseProcessor,
        commonAttributesFn: FlutterOTel.commonAttributesFunction!,
      );

      if (OTelLog.isDebug()) {
        OTelLog.debug('Created ${kIsWeb ? "HTTP" : "gRPC"} span processor');
      }
    }

    // Create platform-specific metric exporters if not provided
    if (metricExporter == null) {
      // Web platform must use HTTP
      if (OTelLog.isDebug()) {
        OTelLog.debug('Creating HTTP metric exporter for web platform');
      }
      if (middlewareAccountKey != null && middlewareAccountKey.isNotEmpty) {
        metricExporter = OtlpHttpMetricExporter(
          OtlpHttpMetricExporterConfig(
            endpoint: endpoint,
            compression: false, // Web doesn't handle compression well
            headers: {
              "Authorization": middlewareAccountKey,
              "Content-Type": "application/json",
              "Access-Control-Allow-Origin": "*",
              "Origin": "sdk.middleware.io",
            },
          ),
        );
      } else {
        metricExporter = OtlpHttpMetricExporter(
          OtlpHttpMetricExporterConfig(
            endpoint: endpoint,
            compression: false, // Web doesn't handle compression well
          ),
        );
      }
    }

    metricReader ??= PeriodicExportingMetricReader(
      metricExporter,
      interval: Duration(seconds: 1), // Export every second
    );

    await sdk.OTel.initialize(
      endpoint: endpoint,
      secure: secure,
      serviceName: serviceName,
      serviceVersion: serviceVersion,
      tracerName: tracerName,
      tracerVersion: tracerVersion,
      resourceAttributes: resourceAttributes,
      spanProcessor: spanProcessor,
      sampler: sampler ?? AlwaysOnSampler(),
      spanKind: spanKind,
      metricExporter: metricExporter,
      metricReader: metricReader,
      enableMetrics: enableMetrics,
      middlewareAccountKey: middlewareAccountKey,
      detectPlatformResources: detectPlatformResources,
      oTelFactoryCreationFunction: otelFlutterFactoryFactoryFunction,
    );
    //TODO - merge mobile/Flutter specific resources
    //sdk.OTel.defaultResource = sdk.OTel.defaultResourcemerge(flutterResources);
    //Create observers
    _lifecycleObserver = OTelLifecycleObserver();
    _routeObserver = OTelNavigatorObserver();
    _interactionTracker = OTelInteractionTracker();

    WidgetsBinding.instance.addObserver(_lifecycleObserver!);

    // Initialize OTel metrics bridge
    // This connects Flutter metrics to OpenTelemetry
    FlutterOTelMetrics.metricReporter.initialize();
    if (kDebugMode) {
      MetricsService.debugPrintMetricsStatus();
    }

    //TODO - move down to Dartastic but make Dartastic default to null
    if (flushTracesInterval != null) {
      Timer.periodic(flushTracesInterval, (_) {
        sdk.OTel.tracerProvider().forceFlush();
      });
    }
  }

  static Future<void> startSessionRecording() async {
    if (_screenshotManager == null) {
      if (kDebugMode) {
        debugPrint(
          'Screenshot manager not initialized. Check middlewareAccountKey.',
        );
      }
      return;
    }

    try {
      await _screenshotManager!.start(DateTime.now().millisecondsSinceEpoch);
      if (kDebugMode) {
        debugPrint('Session recording started');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to start session recording: $e');
      }
    }
  }

  /// Stop session recording
  static Future<void> stopSessionRecording() async {
    if (_screenshotManager != null) {
      await _screenshotManager!.stop();
      if (kDebugMode) {
        debugPrint('Session recording stopped');
      }
    }
  }

  /// Mask a sensitive view (e.g., password field)
  static void maskView(GlobalKey key) {
    _screenshotManager?.setViewForBlur(key);
  }

  /// Unmask a previously masked view
  static void unmaskView(GlobalKey key) {
    _screenshotManager?.removeSanitizedElement(key);
  }

  /// Get the Tracer instance
  static UITracer get tracer => sdk.OTel.tracer() as UITracer;

  static UITracerProvider get tracerProvider =>
      sdk.OTel.tracerProvider() as UITracerProvider;

  /// Get the MeterProvider instance
  static UIMeterProvider get meterProvider {
    return sdk.OTel.meterProvider() as UIMeterProvider;
  }

  /// Get a Meter with the given name and version
  static UIMeter meter({
    String name = 'flutter.default',
    String? version,
    String? schemaUrl,
  }) {
    return meterProvider.getMeter(
          name: name,
          version: version,
          schemaUrl: schemaUrl,
        )
        as UIMeter;
  }

  /// Starts a span for a screen/route
  /// Normally this will be handled automatically by the NavigatorObserver
  /// This is useful for manual spans like a subscription popup.
  /// [root] if (route is true, this starts a new trace)
  /// [childRoute] If not a child, this ends an existing screen span.
  /// [spanLinks]
  sdk.Span startScreenSpan(
    String screenName, {
    bool root = false,
    bool childRoute = false,
    Attributes? attributes,
    List<SpanLink>? spanLinks,
  }) {
    // TODO
    // if (!tracer.enabled) {
    //   return tracer.emptySpan();
    // }
    if (root && childRoute) {
      throw ArgumentError('root cannot be a child route');
    }
    if (!childRoute) {
      // End any existing spans
      endScreenSpan(screenName);
    }
    if (root) {
      //TODO - end all the spans in the path
    }
    final span = tracer.startSpan(
      'screen.$screenName',
      kind: SpanKind.client,
      attributes:
          {'ui.screen.name': screenName, 'ui.type': 'screen'}.toAttributes(),
    );

    _activeSpans[screenName] = span;
    return span;
  }

  /// Ends the span for a screen/route
  void endScreenSpan(String screenName) {
    if (!tracer.enabled) return;

    final span = _activeSpans[screenName];
    if (span != null) {
      span.end();
      _activeSpans.remove(screenName);
    }
  }

  /// Creates and immediately ends a span for a user interaction
  void recordUserInteraction(
    String screenName,
    String interactionType, {
    String? targetName,
    Duration? responseTime,
    Map<String, dynamic>? attributes,
  }) {
    if (!tracer.enabled) return;

    // Create interaction attributes
    final interactionAttributes = <String, Object>{
      'ui.screen.name': screenName,
      'ui.interaction.type': interactionType,
      if (targetName != null) 'ui.interaction.target': targetName,
      if (responseTime != null)
        'ui.interaction.response_time_ms': responseTime.inMilliseconds,
      ...?attributes,
    };

    // Record as span
    final spanName = 'interaction.$screenName.$interactionType';
    final span = tracer.startSpan(
      spanName,
      kind: SpanKind.client,
      attributes: interactionAttributes.toAttributes(),
    );

    if (responseTime != null) {
      // Set the end time based on the response time
      span.end(endTime: span.startTime.add(responseTime));

      // Also record as a metrics histogram
      meter(name: 'flutter.interaction')
          .createHistogram(
            name: 'interaction.response_time',
            description: 'User interaction response time',
            unit: 'ms',
          )
          .record(
            responseTime.inMilliseconds,
            interactionAttributes.toAttributes(),
          );
    } else {
      span.end();

      // Record as a simple counter
      meter(name: 'flutter.interaction')
          .createCounter(
            name: 'interaction.count',
            description: 'User interaction count',
            unit: '{interactions}',
          )
          .add(1, interactionAttributes.toAttributes());
    }
  }

  /// Records a navigation event between routes
  void recordNavigation(
    String fromRoute,
    String toRoute,
    String navigationType,
    Duration duration,
  ) {
    if (!tracer.enabled) return;

    // Create navigation attributes
    final navAttributes = {
      'ui.navigation.from': fromRoute,
      'ui.navigation.to': toRoute,
      'ui.navigation.type': navigationType,
      'event.type': 'navigation',
    };

    // Record as span
    final spanName = 'navigation.$navigationType';
    final span = tracer.startSpan(
      spanName,
      kind: SpanKind.client,
      attributes: navAttributes.toAttributes(),
    );

    span.end(endTime: span.startTime.add(duration));

    // Also record as metric
    meter(name: 'flutter.navigation')
        .createHistogram(
          name: 'navigation.duration',
          description: 'Navigation transition time',
          unit: 'ms',
        )
        .record(duration.inMilliseconds, navAttributes.toAttributes());
  }

  /// Records an error within the current context
  static void reportError(
    String message,
    dynamic error,
    StackTrace? stackTrace, {
    Map<String, dynamic>? attributes,
  }) {
    try {
      OTelLog.error('Flutter error reported: $message \nStack: $stackTrace');
      if (OTelFactory.otelFactory == null) {
        debugPrint('Error before OTel initialization: $message, $error');
        debugPrintStack(stackTrace: stackTrace);
        return; //cannot, too early
      }
      if (!tracer.enabled) return;

      // Create attribute map
      final errorAttributes = <String, Object>{
        'error.context': message,
        'error.type': error.runtimeType.toString(),
        'error.message': error.toString(),
        ...?attributes,
      };

      // Record as span
      final span = tracer.startSpan(
        'error.$message',
        kind: SpanKind.client,
        attributes: errorAttributes.toAttributes(),
      );

      span.recordException(error, stackTrace: stackTrace, escaped: true);
      span.setStatus(SpanStatusCode.Error, error.toString());
      span.end();

      // Also record as a metric counter
      meter(name: 'flutter.errors')
          .createCounter(
            name: 'error.count',
            description: 'Error counter',
            unit: '{errors}',
          )
          .add(1, errorAttributes.toAttributes());
    } catch (e, s) {
      // TODO - best alternative?
      OTelLog.error('Error when reporting the Flutter error: $e \n$s');
    }
  }

  /// Records a performance metric
  static void recordPerformanceMetric(
    String name,
    Duration duration, {
    Map<String, dynamic>? attributes,
  }) {
    if (!tracer.enabled) return;

    // Record in both spans and metrics
    final span = tracer.startSpan(
      'perf.$name',
      kind: SpanKind.client,
      attributes:
          <String, Object>{
            'perf.metric.name': name,
            'perf.duration_ms': duration.inMilliseconds,
            ...?attributes,
          }.toAttributes(),
    );

    span.end(endTime: span.startTime.add(duration));

    // Also record as a metric for proper aggregation
    meter(name: 'flutter.performance')
        .createHistogram(
          name: 'perf.$name',
          description: 'Performance measurement for $name',
          unit: 'ms',
        )
        .record(
          duration.inMilliseconds,
          <String, Object>{
            'perf.metric.name': name,
            ...?attributes,
          }.toAttributes(),
        );
  }

  /// Clean up resources
  void dispose() {
    if (_lifecycleObserver != null) {
      _lifecycleObserver!.dispose();
    }
    stopSessionRecording();
    forceFlush();
  }

  /// Sends all pending OTel data
  static forceFlush() {
    tracerProvider.forceFlush(); //TODO - await
    meterProvider.forceFlush();
  }

  @visibleForTesting
  static reset() {
    // ignore: invalid_use_of_visible_for_testing_member
    sdk.OTel.reset();
    try {
      WidgetsBinding.instance.removeObserver(FlutterOTel.lifecycleObserver);
    } catch (e) {
      // Ignore errors when observer isn't registered
    }
  }
}

/// Extension methods for Flutter widgets to simplify OpenTelemetry integration
// TODO doc usage
extension OTelWidgetExtension on Widget {
  /// Wraps a widget with OpenTelemetry error boundary
  Widget withOTelErrorBoundary(String context) {
    return Builder(
      builder: (buildContext) {
        ErrorWidget.builder = (FlutterErrorDetails errorDetails) {
          // Record error in OpenTelemetry
          final tracer = FlutterOTel.tracer;
          var errorWidget = errorDetails.context;
          String widgetName =
              errorWidget == null
                  ? errorWidget.runtimeType.toString()
                  : 'Unknown';
          tracer.recordError(
            context,
            errorDetails.exception,
            errorDetails.stack,
            attributes: {
              'error.context': 'widget_build',
              'error.widget': widgetName,
              'error.stack': errorDetails.stack.toString(),
              'error.message': errorDetails.exception.toString(),
              'error.type': errorDetails.exception.runtimeType.toString(),
            },
          );

          // Return original error widget
          return ErrorWidget(errorDetails.exception);
        };

        return this;
      },
    );
  }
}
