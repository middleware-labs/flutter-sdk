// Licensed under the Apache License, Version 2.0

import 'package:middleware_dart_opentelemetry/middleware_dart_opentelemetry.dart'
    as sdk;

class OTelRouteData {
  final String routeName;

  /// a spanId equivalent for a route
  final sdk.SpanId routeSpanId;
  final String routePath;
  final String routeArguments;
  final String routeKey;
  final DateTime timestamp;

  OTelRouteData({
    required this.routeSpanId,
    required this.routeName,
    required this.routePath,
    required this.routeArguments,
    required this.routeKey,
  }) : timestamp = DateTime.now();

  static OTelRouteData empty() {
    return OTelRouteData(
      routeSpanId: sdk.OTel.spanIdInvalid(),
      routeName: '',
      routePath: '',
      routeArguments: '',
      routeKey: '',
    );
  }
}
