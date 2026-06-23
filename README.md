# Middleware Flutter OpenTelemetry SDK for Flutter

[![pub.dev](https://img.shields.io/pub/v/middleware_flutter_opentelemetry.svg)](https://pub.dev/packages/middleware_flutter_opentelemetry)

[//]: # ([![Flutter CI]&#40;https://github.com/middleware-labs/flutter-sdk/actions/workflows/flutter.yml/badge.svg&#41;]&#40;https://github.com/middleware-labs/flutter-sdk/actions/workflows/flutter.yml&#41;)

[//]: # ([![codecov]&#40;https://codecov.io/gh/middleware-labs/flutter-sdk/branch/main/graph/badge.svg&#41;]&#40;https://codecov.io/gh/middleware-labs/flutter-sdk&#41;)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Middleware Flutter OTel is an OpenTelemetry SDK for Flutter applications built on the [Middleware OpenTelemetry SDK](https://pub.dev/packages/middleware_dart_opentelemetry), providing comprehensive observability for Flutter applications across all platforms.

## Demo

The [Wondrous OpenTelemetry](https://github.com/middleware-labs/flutter-wonderous-app-opentelemetry) project instruments the Wondrous App for observability with Middleware Flutter OTel. 
The `main.dart` and `router.dart` show how to set up your app with Middleware Flutter OpenTelemetry.

## Overview

Flutterrific OpenTelemetry implements the [OpenTelemetry](https://opentelemetry.io/) specification for Flutter, enabling developers to collect **traces**, **metrics**, and **logs** from Flutter applications. OpenTelemetry is a vendor-neutral standard for observability and is the second most active [Cloud Native Computing Foundation (CNCF)](https://www.cncf.io/) project, after Kubernetes.

## Why OpenTelemetry for Flutter?

- **Report Errors**: Get notified of errors in real time with structured context
- **App Lifecycle**: Track when users launch, pause, resume, and quit
- **Watch Your Users**: Understand navigation flows and improve conversion rates
- **Get Metrics**: Measure route load times, frame rates, and APDEX scores in production
- **Structured Logs**: Emit OTel Events for lifecycle, navigation, errors, and custom telemetry
- **Future-Proof**: OpenTelemetry is an industry standard with broad ecosystem support
- **Vendor Neutral**: Works with any OpenTelemetry-compatible backend (Grafana, Elastic, Datadog, etc.)
- **Cross-Platform**: Supports all Flutter platforms (Android, iOS, Web, Desktop)
- **Performance**: Designed for minimal overhead in production applications

## Features

- 🚀 **Simple Integration**: Get started with just a few lines of code
- 👣 **Automatic Instrumentation**: Navigation, app lifecycle, and user interaction tracking
- 📹 **Session Replay**: Lightweight Session replay of application.
- 📊 **Performance Metrics**: Web vitals, APDEX scores, and custom performance metrics
- 🧩 **Widget Extensions**: Easy-to-use extensions for widget-level observability
- 🐞 **Error Tracking**: Comprehensive error handling and reporting
- 📐 **Standards Compliant**: Full adherence to OpenTelemetry specification
- 🌐 **Multi-Platform**: Supports Android, iOS, Web, and Desktop platforms
- 💪 **Context Propagation**: Seamless trace correlation across async boundaries
- 🔧 **Configurable Sampling**: Multiple sampling strategies for cost optimization
- 🧷 **Type-Safe Semantics**: Strongly-typed semantic conventions

## Quick Start

### 1. Add Dependency

```yaml
dependencies:
  middleware_flutter_opentelemetry: ^1.0.0
```

### 2. Initialize

```dart
import 'package:flutter/material.dart';
import 'package:middleware_flutter_opentelemetry/flutterrific_otel.dart';

  // Initialize error handling
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterOTel.reportError(
      'FlutterError.onError', details.exception, details.stack);
  };

  runZonedGuarded(() {
    // Initialize OpenTelemetry
    FlutterOTel.initialize(
      serviceName: 'my-flutter-app',
      serviceVersion: '1.0.0',
      tracerName: 'main',
      middlewareAccountKey: "*****", // Obtain from RUM Flutter installation page
      endpoint: 'https://<account>.middleware.io',  
      // Configure your exporter endpoint
      resourceAttributes: {
        'env': 'production',
        'service.namespace': 'mobile-apps',
      }
    );
    
    runApp(MyApp());
  }, (error, stack) {
    FlutterOTel.reportError('Zone Error', error, stack);
  });
}
```

### 3. Add the Route Observer

For GoRouter:

```dart
final router = GoRouter(
  observers: [FlutterOTel.routeObserver],
  routes: [ /* ... */ ],
);
```

For standard Navigator:

```dart
MaterialApp(
  navigatorObservers: [FlutterOTel.routeObserver],
  // ...
);
```

That's it. With these three steps, your app automatically emits traces, metrics, and log events for all lifecycle changes, navigation, and errors.

## Signals In Depth

### Traces

Every auto-instrumented event creates a **short, independent span** with its own trace ID. This avoids the problem of a single long-running trace spanning the entire app session.

```dart
// Access the tracer for custom spans
final tracer = FlutterOTel.tracer;

// Create a custom span
final span = tracer.startSpan('fetch_user_data',
  kind: SpanKind.client,
  attributes: {'user.id': userId}.toAttributes(),
);
try {
  final result = await apiClient.getUser(userId);
  span.setStatus(SpanStatusCode.Ok);
  return result;
} catch (e, stackTrace) {
  span.recordException(e, stackTrace: stackTrace);
  span.setStatus(SpanStatusCode.Error, e.toString());
  rethrow;
} finally {
  span.end();
}
```

The UITracer provides convenience methods:

| Method | Description |
|--------|-------------|
| `startSpan()` | Start a span (must be ended manually) |
| `recordNavChange()` | Record a navigation change (starts and ends span) |
| `recordUserInteraction()` | Record a user interaction (starts and ends span) |
| `recordError()` | Record an error with stack trace |
| `recordPerformanceMetric()` | Record a performance measurement |
| `startNavigationChangeSpan()` | Start a navigation span (caller ends it) |
| `startAppLifecycleSpan()` | Start a lifecycle span (caller ends it) |

### Metrics

Metrics are automatically collected via `OTelMetricsBridge`:

| Metric | Type | Description |
|--------|------|-------------|
| `flutter.frame.duration` | Histogram | Frame rendering times (ms) |
| `flutter.page.load_time` | Histogram | Page load times (ms) |
| `flutter.navigation.duration` | Histogram | Navigation transition times (ms) |
| `flutter.errors.count` | Counter | Error count |
| `flutter.interaction.response_time` | Histogram | User interaction response times (ms) |
| `flutter.paint.duration` | Histogram | Paint operation durations (ms) |
| `flutter.layout.shift_score` | Histogram | Layout shift scores |
| `flutter.apdex.score` | Gauge | APDEX performance index |

You can also record custom metrics:

```dart
// Using FlutterOTelMetrics
FlutterOTelMetrics.recordMetric(
  name: 'my_custom_metric',
  value: 42,
  unit: 'ms',
  metricType: 'histogram',
);

// Or directly with a Meter
final meter = FlutterOTel.meter(name: 'my-feature');
meter.createCounter(name: 'feature.usage', unit: '{count}')
  .add(1, {'feature.name': 'dark_mode'}.toAttributes());
```

### Logs (OTel Events)

The Log Signal emits structured OTel Events — log records with an `EventName` field that identifies the event type. This follows the emerging OTel client instrumentation standard.

#### UILogger

`UILogger` wraps the SDK `Logger` with Flutter-specific convenience methods:

```dart
final logger = FlutterOTel.logger('my-feature');

// Standard log levels
logger.info('Feature loaded');
logger.warn('Cache miss');
logger.error('Failed to fetch data');

// Structured OTel Events
logger.emitEvent('user.action',
  body: 'Button tapped',
  attributes: {'button.id': 'submit'}.toAttributes(),
);

// Flutter error logging
FlutterError.onError = (details) {
  logger.emitFlutterError(details);
};

// Lifecycle events (auto-emitted when enableAutoLogEvents is true)
logger.emitLifecycleEvent('resumed', previousState: 'paused');

// Navigation events (auto-emitted when enableAutoLogEvents is true)
logger.emitNavigationEvent('/details', fromRoute: '/home', action: 'push');
```

#### Auto Log Events

When `enableAutoLogEvents` is `true` (the default), Flutterrific automatically emits structured log events for:

| Event Name | Trigger | Key Attributes |
|------------|---------|----------------|
| `device.app.lifecycle` | App lifecycle state change | `app_lifecycle.state`, `app_lifecycle.previous_state`, `app_lifecycle.duration` |
| `browser.navigation` | Route change | `navigation.route.name`, `navigation.previous_route_name`, `navigation.action` |
| `device.app.error` | `FlutterOTel.reportError()` | `error.type`, `error.message`, `exception.stacktrace` |

Set `enableAutoLogEvents: false` in `initialize()` to disable automatic log events while keeping manual logger access.

## Semantic Conventions

Flutterrific uses strongly-typed semantic enums for all attribute keys, following OTel conventions.

### From the OTel Spec (via Dartastic API)

These enums come from the standard OTel semantic conventions:

- `NavigationSemantics` — `navigation.route.name`, `navigation.action`, etc.
- `AppLifecycleSemantics` — `app_lifecycle.state`, `app_lifecycle.duration`, etc.
- `ErrorSemantics` — `error.type`, `error.message`, etc.
- `InteractionSemantics` — `interaction.type`, `interaction.target`, etc.
- `PerformanceSemantics` — `render.duration`, `frame.rate`, etc.
- `SessionViewSemantics` — `view.name`, `session.id`, etc.
- `UserSemantics` — `user.id`, `user.role`, etc.

### Flutter-Specific Proposals

These enums are defined in `FlutterSemantics` and are proposed additions to the OTel client instrumentation spec. They cover areas not yet standardized:

- `FlutterErrorSemantics` — `error.context`, `error.widget`, `error.widget_context`, `error.location`
- `FlutterPerformanceSemantics` — `perf.metric.name`, `perf.duration_ms`
- `FlutterUISemantics` — `ui.type`
- `FlutterScrollSemantics` — `scroll.position`
- `FlutterRedirectSemantics` — `redirect.to`
- `FlutterLifecycleMetricSemantics` — `lifecycle.state` (metric context)
- `FlutterRouteMetricSemantics` — `route.name`, `route.action`, `navigation.from_route`, `navigation.to_route`
- `FlutterEventNames` — `device.app.lifecycle`, `device.app.error`, `browser.navigation`

## Configuration

### Initialize Options

```dart
await FlutterOTel.initialize(
  // Required
  serviceName: 'my-app',

  // Optional — all have sensible defaults
  appName: 'My App',                    // defaults to serviceName
  serviceVersion: '1.0.0',
  endpoint: 'https://collector:4317',   // defaults to localhost:4317

  // Traces
  spanProcessor: null,                  // auto-creates BatchSpanProcessor
  sampler: AlwaysOnSampler(),
  flushTracesInterval: Duration(seconds: 30),

  // Metrics
  enableMetrics: true,
  metricExporter: null,                 // auto-creates platform-specific exporter
  metricReader: null,                   // auto-creates PeriodicExportingMetricReader

  // Logs
  enableLogs: true,
  logRecordExporter: null,              // auto-creates platform-specific exporter
  logRecordProcessor: null,
  logPrint: false,                      // bridge Dart print() to OTel logs
  enableAutoLogEvents: true,            // auto-emit lifecycle/nav/error events

  // Resources
  resourceAttributes: null,
  detectPlatformResources: true,
  commonAttributesFunction: null,       // called on every span creation

  // Security
  secure: true,
  dartasticApiKey: null,
  tenantId: null,
);
```

### Platform-Specific Exporters

Flutterrific automatically selects the right protocol:

| Platform | Traces | Metrics | Logs |
|----------|--------|---------|------|
| Android, iOS, Desktop | OTLP/gRPC | OTLP/gRPC | OTLP/gRPC |
| Web | OTLP/HTTP | OTLP/HTTP | OTLP/HTTP |

Web browsers cannot use gRPC due to browser limitations, so Flutterrific automatically switches to HTTP for web builds.

### Common Attributes

Use `commonAttributesFunction` to add attributes to every span (e.g., user ID, session info):

```dart
await FlutterOTel.initialize(
  serviceName: 'my-app',
  commonAttributesFunction: () => {
    UserSemantics.userId.key: currentUser.id,
    UserSemantics.userRole.key: currentUser.role,
    SessionViewSemantics.sessionId.key: sessionManager.currentSessionId,
  }.toAttributes(),
);
```

### Environment Variables

Standard OpenTelemetry environment variables are supported via `--dart-define`:

```bash
flutter run \
  --dart-define=OTEL_SERVICE_NAME=my-flutter-app \
  --dart-define=OTEL_SERVICE_VERSION=1.0.0 \
  --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://collector:4317 \
  --dart-define=OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  --dart-define=OTEL_EXPORTER_OTLP_HEADERS=api-key=your-api-key
```

| Variable | Description | Default |
|----------|-------------|---------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector endpoint | `http://localhost:4317` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | Protocol (`grpc` or `http/protobuf`) | `grpc` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Additional headers | None |
| `OTEL_SERVICE_NAME` | Service name | None |
| `OTEL_SERVICE_VERSION` | Service version | None |
| `OTEL_LOG_LEVEL` | SDK internal log level | `INFO` |
| `OTEL_CONSOLE_EXPORTER` | Add console exporter for debugging | `false` |

Signal-specific variables (`OTEL_EXPORTER_OTLP_TRACES_*`, `OTEL_EXPORTER_OTLP_METRICS_*`) are also supported and take precedence.

## Developer's Guide

### Widget-Level Tracking

```dart
// Track button interactions
ElevatedButton(
  onPressed: handleSubmit,
  child: Text('Submit'),
).withOTelButtonTracking('submit_form');

// Error boundaries
RiskyWidget().withOTelErrorBoundary('risky_operation');

// Track interactions via the interaction tracker
FlutterOTel.interactionTracker.trackButtonClick(context, 'submit_btn');
FlutterOTel.interactionTracker.trackScroll(context, 'feed_list', scrollPosition);
FlutterOTel.interactionTracker.trackSwipeGesture(context, 'card', 'left');
```

### Manual Screen Spans

```dart
// Start a screen span (creates a new trace)
final span = FlutterOTel().startScreenSpan('checkout');

// ... user interacts with screen ...

// End when leaving
FlutterOTel().endScreenSpan('checkout');
```

### Error Reporting

```dart
// Report errors from any zone
FlutterOTel.reportError('network_error', error, stackTrace,
  attributes: {'endpoint': '/api/users'},
);

// In Flutter error handler
FlutterError.onError = (details) {
  FlutterOTel.reportError(
    'FlutterError', details.exception, details.stack);
};

// For async errors
PlatformDispatcher.instance.onError = (error, stack) {
  FlutterOTel.reportError('PlatformError', error, stack);
  return true;
};
```

### Custom OTel Events

```dart
final logger = FlutterOTel.logger('checkout');

// Emit a structured event
logger.emitEvent('checkout.completed',
  body: 'Order placed successfully',
  attributes: {
    'order.id': orderId,
    'order.total': total,
    'payment.method': 'credit_card',
  }.toAttributes(),
);
```

### Testing

For widget tests, use `SimpleSpanProcessor` with `ConsoleExporter` to avoid gRPC timer conflicts with `FakeAsync`:

```dart
import 'package:flutterrific_opentelemetry/flutterrific_opentelemetry.dart';

Future<void> initializeForTest() async {
  await FlutterOTel.initialize(
    endpoint: 'http://localhost:4317',
    serviceName: 'test-service',
    spanProcessor: SimpleSpanProcessor(ConsoleExporter()),
    enableMetrics: false,
    enableLogs: false,
    flushTracesInterval: null,   // No periodic timer in tests
    detectPlatformResources: false,
  );
}

// In tests:
setUp(() async {
  await FlutterOTel.reset();
  await initializeForTest();
});

tearDown(() async {
  await FlutterOTel.reset();
});
```

### Local Development

Run an OpenTelemetry collector locally:

```bash
# Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) — all-in-one
docker run -p 3000:3000 -p 4317:4317 -p 4318:4318 --rm -ti grafana/otel-lgtm
```

Then open Grafana at `http://localhost:3000` to see traces, metrics, and logs.

### Flushing Data

```dart
// Force flush all pending data (traces, metrics, logs)
FlutterOTel.forceFlush();
```

By default, traces are flushed every 30 seconds. Set `flushTracesInterval` to change this, or `null` to disable periodic flushing.

### Cleanup

```dart
// Clean up on app shutdown
FlutterOTel().dispose();
```

### 3. Session Replay

Flutter SDK has the capability of session recording, to start session recording call `FlutterOTel.startSessionRecording();`  
& to stop session recording call `FlutterOTel.stopSessionRecording()`

```dart
class MyAppState extends State<MyApp> {
  
  @override
  void initState() {
    Timer(Duration(milliseconds: 500), () {
      FlutterOTel.startSessionRecording();
    });
    super.initState();
  }
  
  @override
  void dispose(){
    try {
      FlutterOTel.stopSessionRecording();
    } catch (e) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
        key: FlutterOTel.repaintBoundaryKey,
        child: ...;
  }
}
```

## Platform Support

| Platform | Support Level | Protocol  | Notes                                    |
|----------|---------------|-----------|------------------------------------------|
| Android  | Full          | OTLP/gRPC | Complete feature support                 |
| iOS      | Full          | OTLP/gRPC | Complete feature support                 |
| Web      | Full          | OTLP/HTTP | Auto-switches due to browser limitations |
| Windows  | Beta          | OTLP/gRPC | Desktop support                          |
| macOS    | Beta          | OTLP/gRPC | Desktop support                          |
| Linux    | Beta          | OTLP/gRPC | Desktop support                          |

## Environment Variables

Middleware OpenTelemetry supports standard OpenTelemetry environment variables as defined in the [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/otel/configuration/sdk-environment-variables/).

These environment variables can be set to configure the SDK behavior without changing code. Signal-specific variables take precedence over general ones.

### Service Configuration

| Variable                   | Description                                                       | Example                                 |
|----------------------------|-------------------------------------------------------------------|-----------------------------------------|
| `OTEL_SERVICE_NAME`        | Sets the service name                                             | `my-dart-app`                           |
| `OTEL_SERVICE_VERSION`     | Sets the service version                                          | `1.0.0`                                 |
| `OTEL_RESOURCE_ATTRIBUTES` | Additional resource attributes as comma-separated key=value pairs | `environment=production,region=us-west` |

### OTLP Exporter Configuration

| Variable                         | Description                                           | Default                                                            | Example                              |
|----------------------------------|-------------------------------------------------------|--------------------------------------------------------------------|--------------------------------------|
| `OTEL_EXPORTER_OTLP_ENDPOINT`    | The OTLP endpoint URL                                 | `http://localhost:4317` for gRPC, `http://localhost:4318` for HTTP | `https://otel-collector:4317`        |
| `OTEL_EXPORTER_OTLP_PROTOCOL`    | The protocol to use                                   | `http/protobuf`                                                    | `grpc`, `http/protobuf`, `http/json` |
| `OTEL_EXPORTER_OTLP_HEADERS`     | Additional headers as comma-separated key=value pairs | None                                                               | `api-key=secret,tenant=acme`         |
| `OTEL_EXPORTER_OTLP_INSECURE`    | Whether to use insecure connection                    | `false`                                                            | `true`                               |
| `OTEL_EXPORTER_OTLP_TIMEOUT`     | Export timeout in milliseconds                        | `10000`                                                            | `5000`                               |
| `OTEL_EXPORTER_OTLP_COMPRESSION` | Compression to use                                    | None                                                               | `gzip`                               |

### Signal-Specific Configuration

#### Traces

| Variable                                | Description                      | Default                  | Example                      |
|-----------------------------------------|----------------------------------|--------------------------|------------------------------|
| `OTEL_TRACES_EXPORTER`                  | Trace exporter to use            | `otlp`                   | `console`, `none`            |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`    | Traces-specific endpoint         | Uses general endpoint    | `https://traces.example.com` |
| `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL`    | Traces-specific protocol         | Uses general protocol    | `grpc`                       |
| `OTEL_EXPORTER_OTLP_TRACES_HEADERS`     | Traces-specific headers          | Uses general headers     | `trace-key=value`            |
| `OTEL_EXPORTER_OTLP_TRACES_INSECURE`    | Traces-specific insecure setting | Uses general setting     | `true`                       |
| `OTEL_EXPORTER_OTLP_TRACES_TIMEOUT`     | Traces-specific timeout          | Uses general timeout     | `30000`                      |
| `OTEL_EXPORTER_OTLP_TRACES_COMPRESSION` | Traces-specific compression      | Uses general compression | `gzip`                       |

#### Metrics

| Variable                                 | Description                       | Default                  | Example                       |
|------------------------------------------|-----------------------------------|--------------------------|-------------------------------|
| `OTEL_METRICS_EXPORTER`                  | Metrics exporter to use           | `otlp`                   | `console`, `none`             |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`    | Metrics-specific endpoint         | Uses general endpoint    | `https://metrics.example.com` |
| `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL`    | Metrics-specific protocol         | Uses general protocol    | `http/protobuf`               |
| `OTEL_EXPORTER_OTLP_METRICS_HEADERS`     | Metrics-specific headers          | Uses general headers     | `metric-key=value`            |
| `OTEL_EXPORTER_OTLP_METRICS_INSECURE`    | Metrics-specific insecure setting | Uses general setting     | `false`                       |
| `OTEL_EXPORTER_OTLP_METRICS_TIMEOUT`     | Metrics-specific timeout          | Uses general timeout     | `60000`                       |
| `OTEL_EXPORTER_OTLP_METRICS_COMPRESSION` | Metrics-specific compression      | Uses general compression | `gzip`                        |

### Logging Configuration

| Variable                | Description                        | Example                                            |
|-------------------------|------------------------------------|----------------------------------------------------|
| `OTEL_LOG_LEVEL`        | SDK internal log level             | `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL` |
| `OTEL_LOG_METRICS`      | Enable metrics logging             | `true`, `1`, `yes`, `on`                           |
| `OTEL_LOG_SPANS`        | Enable spans logging               | `true`, `1`, `yes`, `on`                           |
| `OTEL_LOG_EXPORT`       | Enable export logging              | `true`, `1`, `yes`, `on`                           |
| `OTEL_CONSOLE_EXPORTER` | Add console exporter for debugging | `true`, `1`, `yes`, `on`                           |

### Usage Example with Flutter

When running a Flutter app:

```bash
flutter run \
  --dart-define=OTEL_SERVICE_NAME=my-flutter-app \
  --dart-define=OTEL_SERVICE_VERSION=1.0.0 \
  --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://otel-collector:4317 \
  --dart-define=OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
  --dart-define=OTEL_EXPORTER_OTLP_HEADERS=Authorization=your-api-key
```

## Advanced Usage

### Custom Tracing

```dart
void fetchUserData() async {
  final tracer = FlutterOTel.tracer;
  
  final span = tracer.startSpan('fetch_user_data', attributes: {
    'user.id': userId,
    'api.endpoint': '/users',
  });
  
  try {
    final result = await apiClient.getUser(userId);
    span.setStatus(SpanStatusCode.Ok);
    return result;
  } catch (e, stackTrace) {
    span.recordException(e, stackTrace: stackTrace);
    span.setStatus(SpanStatusCode.Error, e.toString());
    rethrow;
  } finally {
    span.end();
  }
}
```

### Widget-Level Tracking

```dart
// Track button interactions
ElevatedButton(
  onPressed: handleSubmit,
  child: Text('Submit'),
).withOTelButtonTracking('submit_form');

// Track text field
TextField(
  decoration: const InputDecoration(
    labelText: 'Enter something',
    border: OutlineInputBorder(),
  ),
).withOTelTextFieldTracking('demo_text_field')

// Error boundaries
RiskyWidget().withOTelErrorBoundary('risky_operation');
```

    ## Configuration
    
    ### Environment Variables
    
    Standard OpenTelemetry environment variables are supported:
    
    ```bash
    # Exporter endpoint
    --dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://your-collector:4317
    
    # Protocol selection (default is http/protobuf as per OTel spec)
    --dart-define=OTEL_EXPORTER_OTLP_PROTOCOL=grpc
    
    # Service information
    --dart-define=OTEL_SERVICE_NAME=my-flutter-app
    --dart-define=OTEL_SERVICE_VERSION=1.0.0
    ```
    
    ### Local Development
    
    For local development, run an OpenTelemetry collector on localhost:4317, the default. 
    
    ```bash
    docker run -p 3000:3000 -p 4317:4317 -p 4318:4318 --rm -ti grafana/otel-lgtm
    ```
## Examples

- [Basic Integration Example](example/)
- [Flutter_Wonderous OpenTelemetry](https://github.com/middleware-labs/flutter-wonderous-app-opentelemetry) - Complete app example based on Wonderous

## Contributing

We are looking for contributors and maintainers! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

### Development Setup

```bash
# Clone the repository
git clone https://github.com/middleware-labs/flutter-sdk.git
cd flutter-sdk

# Install dependencies
make install

# Run tests
make test

# Run all checks
make all
```

## Governance

This project follows the [CNCF Code of Conduct](https://github.com/cncf/foundation/blob/main/code-of-conduct.md) and maintains [open governance](GOVERNANCE.md). We welcome community participation and contributions.

## Security

Security vulnerabilities should be reported privately to the maintainers. See our [Security Policy](SECURITY.md) for details.

## Roadmap

See our [Roadmap](ROADMAP.md) for planned features and improvements.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Community

- [GitHub Issues](https://github.com/middleware-labs/flutter-sdk/issues) - Bug reports and feature requests
- [OpenTelemetry Community](https://opentelemetry.io/community/) - Broader OpenTelemetry community

## Acknowledgments

Built on the foundation of:
- [Middleware OpenTelemetry SDK](https://pub.dev/packages/middleware_dart_opentelemetry)
- [Dartastic OpenTelemetry API](https://pub.dev/packages/dartastic_opentelemetry_api)
- [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/otel/)
- [Flutter Framework](https://flutter.dev/)
