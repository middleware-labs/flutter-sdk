# Governance Model for OpenTelemetry SDK for Flutter

This document outlines the governance model for the OpenTelemetry SDK for Flutter project, which aims to align with the Cloud Native Computing Foundation (CNCF) OpenTelemetry project's governance structure while being adapted for the specific needs of this Flutter implementation.

## Project Maintainers

The project is currently maintained by:

- Michael Bushe ([@michaelbushe](https://github.com/michaelbushe)) - Lead Maintainer

Maintainers are responsible for:

- Reviewing and merging pull requests
- Triaging issues and managing the issue tracker
- Ensuring code quality and adherence to OpenTelemetry specifications
- Managing releases
- Handling security issues
- Making decisions about the project's direction
- Coordinating with the Flutter community and ecosystem

## Decision Making Process

Decisions about the project are made through consensus among maintainers. For significant changes that affect the SDK compatibility, Flutter integration patterns, or project direction:

1. A proposal should be submitted as a GitHub issue
2. The proposal will be discussed publicly
3. Maintainers will seek consensus
4. If consensus cannot be reached, a vote will be taken among maintainers, with a simple majority required for approval

## Becoming a Maintainer

New maintainers are added through the following process:

1. Demonstrate sustained, high-quality contributions to the project
2. Show understanding of the project's goals and OpenTelemetry specifications
3. Demonstrate understanding of Flutter development patterns and best practices
4. Be nominated by an existing maintainer
5. Gain approval from a majority of existing maintainers

## Contributions

We welcome contributions from all members of the community. Please refer to the [CONTRIBUTING.md](CONTRIBUTING.md) file for guidelines on how to contribute.

## Code of Conduct

All participants in the project are expected to follow the CNCF Code of Conduct available at [https://github.com/cncf/foundation/blob/main/code-of-conduct.md](https://github.com/cncf/foundation/blob/main/code-of-conduct.md).

## Relationship with OpenTelemetry Project

This project aims to be a compliant implementation of the OpenTelemetry specification for Flutter. While we maintain our own governance for this specific implementation, we:

- Follow the OpenTelemetry specification
- Implement the [OpenTelemetry SDK for Flutter](https://pub.dev/packages/flutterrific_opentelemetry)
- Seek alignment with the broader OpenTelemetry community
- Prioritize interoperability with other OpenTelemetry implementations
- Support compatibility with the OpenTelemetry Collector
- Participate in relevant OpenTelemetry SIGs (Special Interest Groups)
- Coordinate with the Flutter team and ecosystem

## Changes to Governance

Changes to this governance document should be proposed via pull request and require approval from a majority of maintainers.

## CNCF Alignment

As part of our goal to potentially contribute this project to the CNCF OpenTelemetry organization, we align with CNCF governance principles:

- Open Source (Apache 2.0 license)
- Open Governance
- Open Contributions
- Open Technical Decisions

## Security Issues

Security vulnerabilities should be reported privately to the maintainers. See [SECURITY.md](SECURITY.md) for details.

## Versioning and Stability

The project follows semantic versioning and provides stability guarantees as documented in [VERSIONING.md](VERSIONING.md).

## Relation to Other Dart OpenTelemetry Projects

This Flutter SDK builds upon and extends the [OpenTelemetry SDK for Dart](https://pub.dev/packages/middleware_dart_opentelemetry) and [OpenTelemetry API for Dart](https://pub.dev/packages/dartastic_opentelemetry_api) to provide Flutter-specific functionality. It is designed to be:

- Compatible with the Middleware Dart OpenTelemetry SDK and API
- Interoperable with the OpenTelemetry Collector
- Optimized for Flutter application patterns and lifecycle
- Usable across all Flutter platforms (Android, iOS, Web, Desktop)

This governance model applies specifically to the Flutter SDK implementation, while the underlying Dart SDK and API have their own governance documents.

## Flutter Community Engagement

Given the Flutter-specific nature of this project, we also:

- Engage with the Flutter community through appropriate channels
- Consider Flutter ecosystem patterns and conventions
- Align with Flutter's development practices and guidelines
- Participate in Flutter community discussions relevant to observability
