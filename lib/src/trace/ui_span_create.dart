// Licensed under the Apache License, Version 2.0

part of 'ui_span.dart';

/// Internal constructor access for Span
class UISpanCreate {
  /// Creates a Span, only accessible within library
  static UISpan create({
    required Span delegateSpan,
    required UISpanType? uiSpanType,
    AppLifecycleState? lifecycleState,
  }) {
    return UISpan._(delegateSpan, uiSpanType: uiSpanType);
  }
}
