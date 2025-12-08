# Makefile for Middleware Flutter OpenTelemetry SDK

.PHONY: help install clean test coverage analyze format build publish docs example

# Default target
help:
	@echo "Available targets:"
	@echo "  install     - Install dependencies"
	@echo "  clean       - Clean build artifacts"
	@echo "  test        - Run all tests"
	@echo "  coverage    - Run tests with coverage"
	@echo "  analyze     - Analyze code"
	@echo "  format      - Format code"
	@echo "  build       - Build all platforms"
	@echo "  publish     - Publish to pub.dev (dry run)"
	@echo "  docs        - Generate documentation"
	@echo "  example     - Build example app"
	@echo "  all         - Run all checks (install, test, coverage, analyze, format)"

# Install dependencies
install:
	flutter pub get
	cd example && flutter pub get

# Clean build artifacts
clean:
	flutter clean
	cd example && flutter clean
	rm -rf coverage/
	rm -rf doc/

# Run tests
test:
	flutter test

# Run tests with coverage
coverage:
	flutter test --coverage
	genhtml coverage/lcov.info -o coverage/html
	@echo "Coverage report generated in coverage/html/index.html"

# Analyze code
analyze:
	flutter analyze --fatal-infos

# Format code
format:
	dart format .

# Build all platforms
build: build-android build-ios build-web

# Build Android
build-android:
	cd example && flutter build apk --debug

# Build iOS
build-ios:
	cd example && flutter build ios --debug --no-codesign

# Build Web
build-web:
	cd example && flutter build web

# Publish package (dry run)
publish:
	flutter pub publish --dry-run

# Generate documentation
docs:
	dart doc .

# Build example app on all platforms
example: example-android example-ios example-web

example-android:
	cd example && flutter build apk --debug

example-ios:
	cd example && flutter build ios --debug --no-codesign

example-web:
	cd example && flutter build web

# Run pana analysis
pana:
	dart pub global activate pana
	dart pub global run pana --no-warning --source path .

# Run all checks
all: install test coverage analyze format pana
	@echo "All checks completed successfully!"

# Development setup
dev-setup: install
	@echo "Development environment setup complete!"

# Pre-commit checks
pre-commit: format analyze test
	@echo "Pre-commit checks passed!"

# Release preparation
release-prep: all build example
	@echo "Release preparation complete!"
	@echo "Don't forget to:"
	@echo "  1. Update version in pubspec.yaml"
	@echo "  2. Update CHANGELOG.md"
	@echo "  3. Create git tag"
	@echo "  4. Run 'make publish' to verify"

# Continuous Integration simulation
ci: install analyze test coverage pana build example
	@echo "CI simulation complete!"
