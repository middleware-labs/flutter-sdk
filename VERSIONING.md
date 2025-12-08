# Versioning Strategy

This document outlines the versioning strategy for the OpenTelemetry SDK for Flutter.

## Semantic Versioning

This project follows [Semantic Versioning 2.0.0](https://semver.org/) with the format MAJOR.MINOR.PATCH:

1. **MAJOR** version increments indicate incompatible API changes
2. **MINOR** version increments indicate new functionality added in a backward-compatible manner
3. **PATCH** version increments indicate backward-compatible bug fixes

## Pre-1.0 Development

While the package is in pre-1.0 development (0.x.y):

- MINOR version increments may include breaking changes
- We will attempt to minimize breaking changes, but they may be necessary as we align with the evolving OpenTelemetry specification and Flutter ecosystem
- PATCH version increments will remain backward-compatible bug fixes
- Breaking changes will be clearly documented in the CHANGELOG

## Stability Guarantees

### Flutter SDK Components

Each Flutter SDK component has a stability level:

1. **Stable**: Breaking changes only in major versions after 1.0
2. **Beta**: Generally stable, but breaking changes may occur in minor versions
3. **Alpha**: Experimental, breaking changes may occur in any version

Current stability levels:

| Flutter SDK Component    | Stability Level |
|--------------------------|----------------|
| Navigation Integration   | Beta           |
| Widget Extensions        | Beta           |
| Error Boundary          | Beta           |
| App Lifecycle Tracking  | Beta           |
| User Interaction Tracking| Beta           |
| Flutter Web Support     | Beta           |
| Platform Specific Exports| Beta           |
| Go Router Integration   | Beta           |
| Flutter Metrics         | Beta           |

### Deprecation Policy

- Deprecated features will be marked with the `@deprecated` annotation
- Deprecated features will be documented in the CHANGELOG
- Deprecated features will be supported for at least one minor version before removal
- Removal of deprecated features will only occur in major version updates after 1.0
- Migration guides will be provided for deprecated features

## API Compatibility

The Flutter SDK maintains compatibility with the underlying Dart OpenTelemetry libraries:

- Flutter SDK versions will align with compatible Middleware OpenTelemetry SDK versions
- When the underlying Dart SDK has a breaking change, the Flutter SDK will also increment its major version
- The Flutter SDK will maintain compatibility with at least the current and previous minor version of the Dart SDK
- Platform-specific compatibility will be maintained across supported Flutter versions

## Flutter Version Compatibility

The Flutter SDK supports:

- Current stable Flutter release
- Previous stable Flutter release
- Current beta Flutter release (when possible)

Compatibility matrix:

| Flutter SDK Version | Minimum Flutter Version | Supported Flutter Versions |
|---------------------|------------------------|----------------------------|
| 0.3.x              | 3.7.0                  | 3.7.0 - Current           |

## Platform Support Versioning

Different platforms may have different feature availability:

| Platform | Support Level | Notes |
|----------|---------------|-------|
| Android  | Full          | All features supported |
| iOS      | Full          | All features supported |
| Web      | Full          | OTLP/HTTP used instead of gRPC |
| Windows  | Beta          | Desktop support |
| macOS    | Beta          | Desktop support |
| Linux    | Beta          | Desktop support |

## Alignment with OpenTelemetry Specification

This package aims to align with the OpenTelemetry specification:

- The minor version may increment to align with specification changes
- We track the specification version we implement in our documentation
- Critical specification changes may necessitate breaking changes
- Changes to the OpenTelemetry Protocol (OTLP) may require Flutter SDK updates
- Flutter-specific semantic conventions may be added as extensions

## Dependency Versioning

The Flutter SDK depends on:

- `middleware_dart_opentelemetry`: Major version alignment required
- `dartastic_opentelemetry_api`: Major version alignment required
- `flutter`: Minimum version specified, tested with stable and beta
- Other dependencies: Semantic versioning constraints applied

## Long-Term Support (LTS)

- No formal LTS versions currently exist for this pre-1.0 package
- LTS policies will be established when we reach version 1.0
- Security patches will be backported to supported versions

## Release Schedule

- PATCH releases: As needed for bug fixes and security issues
- MINOR releases: Roughly monthly, aligned with significant feature completions and underlying SDK updates
- MAJOR releases: Only when necessary for breaking changes

## Flutter-Specific Versioning Considerations

### Widget API Changes

- Widget API changes are considered breaking if they affect public interfaces
- Extension method changes are treated as regular API changes
- Changes to optional parameters follow standard semantic versioning

### Platform Feature Parity

- New platform support is considered a minor version increment
- Platform-specific feature additions are minor version increments
- Removal of platform support is a major version increment

### Navigation Framework Support

- Adding support for new navigation frameworks is a minor version increment
- Changes to existing navigation integrations follow standard API versioning
- Removal of navigation framework support is a major version increment

## Breaking Change Policy

Pre-1.0, breaking changes are allowed in minor versions but will be:

1. Clearly documented in the CHANGELOG
2. Announced in the release notes
3. Include migration instructions when possible
4. Minimize impact on existing users
5. Consider deprecation warnings when feasible

Post-1.0, breaking changes will only occur in major version increments.

## Upgrading Guidelines

Upgrade guidelines will be provided in the CHANGELOG.md file with each release, highlighting:

- Breaking changes (if any)
- New features
- Deprecations
- Bug fixes
- Migration guides for major version changes
- Compatibility requirements with Flutter versions
- Platform-specific changes
- Dependency updates

## Version Support Policy

We provide support for:
- Current major version (full support)
- Previous major version (security and critical bug fixes only)
- Pre-1.0 versions (only the latest minor version)

## Communication

Version-related communications will be made through:
- GitHub releases
- pub.dev package updates
- CHANGELOG.md updates
- GitHub issues for breaking change discussions
- Community forums when appropriate
