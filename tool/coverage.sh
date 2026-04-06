#!/bin/bash
# Coverage script for Flutterrific OpenTelemetry

set -e  # Exit on any error

# Parse command line arguments
# Need trace logging for coverage of debug and trace logs
LOG_LEVEL="trace"
CONCURRENCY="20"

while [[ $# -gt 0 ]]; do
  case $1 in
    --log)
      LOG_LEVEL="$2"
      shift 2
      ;;
    --concurrency)
      CONCURRENCY="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--log LEVEL] [--concurrency N]"
      echo "  --log LEVEL        Set log level (trace, debug, info, warn, error, fatal)"
      echo "  --concurrency N    Set test concurrency (default: 20)"
      exit 1
      ;;
  esac
done

echo "Starting test coverage collection..."
# Set environment variables to enable logging during tests
export OTEL_LOG_LEVEL="$LOG_LEVEL"
export OTEL_LOG_METRICS=true
export OTEL_LOG_SPANS=true
export OTEL_LOG_EXPORT=true

echo "Log level: $LOG_LEVEL"
echo "Concurrency: $CONCURRENCY"

# Ensure the coverage directory exists and is clean
rm -rf coverage
mkdir -p coverage

# Run tests with coverage
echo "Running tests with coverage..."
flutter test --coverage --concurrency="$CONCURRENCY" ./test

# flutter test --coverage already generates coverage/lcov.info

# Generate HTML report
genhtml coverage/lcov.info -o coverage/html

echo "Coverage process completed successfully"
exit 0
