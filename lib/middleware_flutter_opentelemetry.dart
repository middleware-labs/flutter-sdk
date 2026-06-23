// Licensed under the Apache License, Version 2.0

library;

export 'src/util/platform_detection.dart';

export 'src/flutterrific_otel.dart';
export 'src/flutterrific_otel_metrics.dart';
export 'src/metrics/flutter_metric_reporter.dart';
export 'src/metrics/metric_collector.dart';
export 'src/metrics/ui_meter.dart';
export 'src/metrics/ui_meter_provider.dart';
export 'src/metrics/otel_metrics_bridge.dart';
export 'src/metrics/metrics_service.dart';
export 'src/nav/otel_navigator_observer.dart';
export 'src/nav/otel_go_router_redirect.dart';
export 'src/common/otel_lifecycle_observer.dart';
export 'src/trace/interaction_tracker.dart';
export 'src/trace/ui_tracer.dart';
export 'src/trace/ui_tracer_provider.dart';
export 'src/session/session_manager.dart';
export 'src/instrumentation/user_interaction_instrumentation.dart';

// Session-replay configuration. Only the public config types are exported;
// the internal capture/upload machinery stays private to the package.
export 'src/recording/session_recording.dart'
    show RecordingOptions, ScreenshotRecordingWrapper;


/// Re-export key Dartastic OpenTelemetry SDK components for convenience
export 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    show
        AttributeSamplingCondition,
        AlwaysOffSampler,
        AlwaysOnSampler,
        BatchSpanProcessor,
        CompositeSampler,
        CompositeResourceDetector,
        ConsoleExporter,
        CountingSampler,
        EnvVarResourceDetector,
        ErrorSamplingCondition,
        HostResourceDetector,
        MetricExporter,
        MetricReader,
        NamePatternSamplingCondition,
        OTel,
        OTelLog,
        OtlpGrpcMetricExporter,
        OtlpGrpcMetricExporterConfig,
        OtlpGrpcExporterConfig,
        OtlpGrpcSpanExporter,
        OtlpHttpMetricExporter,
        OtlpHttpMetricExporterConfig,
        OtlpHttpSpanExporter,
        OtlpHttpExporterConfig,
        ParentBasedSampler,
        PeriodicExportingMetricReader,
        PlatformResourceDetector,
        ProbabilitySampler,
        ProcessResourceDetector,
        RateLimitingSampler,
        Resource,
        ResourceDetector,
        Sampler,
        SamplingDecision,
        SamplingDecisionSource,
        SamplingResult,
        SpanExporter,
        SpanProcessor,
        SamplingCondition,
        Span,
        TracerProvider,
        Tracer,
        TraceIdRatioSampler;
