// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

part of 'ui_logger_provider.dart';

/// Factory for creating [UILoggerProvider] instances.
class UILoggerProviderCreate {
  static UILoggerProvider create({required LoggerProvider delegate}) {
    return UILoggerProvider._(delegate: delegate);
  }
}
