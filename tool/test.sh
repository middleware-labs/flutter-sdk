#!/bin/bash
# Test script for Flutterrific OpenTelemetry

# Parse command line arguments
LOG_LEVEL="info"
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

# Set environment variables if specified
if [ -n "$LOG_LEVEL" ]; then
  export OTEL_LOG_LEVEL="$LOG_LEVEL"
  echo "Setting log level to: $LOG_LEVEL"
fi

# Build dart test command
TEST_CMD="flutter test ./test"

if [ -n "$CONCURRENCY" ]; then
  TEST_CMD="$TEST_CMD --concurrency=$CONCURRENCY"
  echo "Setting concurrency to: $CONCURRENCY"
fi

# Run all tests
echo "Running all tests..."
$TEST_CMD

# Check exit code
if [ $? -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed!"
    exit 1
fi
