# Publication Checklist

This document outlines the steps to follow when publishing a new version of the OpenTelemetry SDK for Flutter.

## Pre-release Checklist

### Code Quality
- [ ] All tests are passing (`flutter test`)
- [ ] Code coverage is at acceptable levels (>85%)
- [ ] No lint warnings (`flutter analyze`)
- [ ] Code is properly formatted (`dart format .`)
- [ ] Package scores well on `pana` analysis
- [ ] Example app builds and runs on all supported platforms

### Flutter-Specific Testing
- [ ] Android build succeeds (`flutter build apk`)
- [ ] iOS build succeeds (`flutter build ios`)
- [ ] Web build succeeds (`flutter build web`)
- [ ] Desktop builds succeed (when applicable)
- [ ] Widget tests pass on all platforms
- [ ] Integration tests pass (if available)
- [ ] Performance tests show acceptable benchmarks

### Documentation
- [ ] Documentation is up-to-date with the current version
- [ ] CHANGELOG.md is updated with all notable changes
- [ ] Version numbers are updated in relevant files
- [ ] Examples demonstrate current Flutter SDK usage and best practices
- [ ] Widget integration examples are current
- [ ] Platform-specific documentation is accurate

### Compatibility
- [ ] Breaking changes are documented and follow versioning policy
- [ ] Compatibility with the OpenTelemetry specification is verified
- [ ] Compatibility with underlying Dart OpenTelemetry SDK is maintained
- [ ] Platform-specific compatibility is tested (Android, iOS, Web, Desktop)
- [ ] Flutter version compatibility is verified
- [ ] Third-party navigation package integrations work correctly

### Continuous Integration
- [ ] All CI checks pass on the main branch
- [ ] All dependencies are up-to-date and secure
- [ ] Integration with OpenTelemetry Collector is tested
- [ ] Multi-platform builds succeed in CI
- [ ] Coverage reports are generated successfully

## Release Process

### 1. Prepare Release
- [ ] Update version in `pubspec.yaml`
- [ ] Update version in example app's `pubspec.yaml`
- [ ] Cut the CHANGELOG.md section: `python3 scripts/changelog.py release <version>`
      (moves the `[Unreleased]` entries under a dated `[<version>]` heading)
- [ ] Update any version references in documentation
- [ ] Create a git tag for the version (e.g., `git tag v0.3.0`)
- [ ] Push the tag to the repository (`git push origin v0.3.0`)

### 2. Pre-publication Verification
- [ ] Run final `flutter pub publish --dry-run` check
- [ ] Verify pub.dev score predictions
- [ ] Test example app with the new version
- [ ] Verify all supported platforms work with example app
- [ ] Check that all required files are included in the package

### 3. Publish to pub.dev
- [ ] Publish with `flutter pub publish`
- [ ] Verify package appears correctly on pub.dev
- [ ] Check that documentation renders properly on pub.dev
- [ ] Verify example code works when copied from pub.dev

### 4. Post-Release
- [ ] Create a GitHub release with release notes
- [ ] Update example apps to use the new version
- [ ] Announce in appropriate Flutter community channels (if applicable)
- [ ] Update documentation website (if applicable)
- [ ] Increment to next development version
- [ ] Update any dependent packages to use the new version
- [ ] Notify users of any migration requirements

## Flutter-Specific Release Considerations

### Platform Testing
- [ ] Test on real Android devices (multiple API levels)
- [ ] Test on real iOS devices (multiple iOS versions)
- [ ] Test in web browsers (Chrome, Safari, Firefox)
- [ ] Test on desktop platforms (if supported)
- [ ] Verify performance on different device classes

### Framework Integration
- [ ] Test with latest stable Flutter release
- [ ] Test with Flutter beta (if possible)
- [ ] Verify navigation integrations work correctly
- [ ] Test widget extensions and tracking
- [ ] Verify app lifecycle tracking works across platforms

### Ecosystem Compatibility
- [ ] Test with popular state management solutions
- [ ] Verify compatibility with common navigation packages
- [ ] Test with popular networking packages
- [ ] Check integration with crash reporting tools

## Emergency Fixes

If an emergency fix is required for a released version:

1. Create a hotfix branch from the tagged release
2. Make minimal required changes
3. Test thoroughly on affected platforms
4. Follow the standard release process but increment the PATCH version
5. Merge the fix back to the main branch if applicable
6. Consider backporting to other supported versions

## CNCF Contribution Considerations

If preparing for CNCF contribution:

- [ ] Ensure all legal requirements are met (license, CLAs, etc.)
- [ ] Review contribution guidelines for the OpenTelemetry organization
- [ ] Prepare documentation specifically required for CNCF review
- [ ] Verify compatibility with other OpenTelemetry implementations
- [ ] Ensure governance documents are complete and current
- [ ] Review security policies and procedures
- [ ] Verify project follows CNCF graduation criteria

## Quality Gates

Before any release, ensure:

### Code Quality Gates
- [ ] Test coverage >85%
- [ ] No critical security vulnerabilities
- [ ] Performance benchmarks meet standards
- [ ] Memory usage is within acceptable limits
- [ ] Package size is reasonable for Flutter applications

### Documentation Gates
- [ ] All public APIs are documented
- [ ] Migration guides exist for breaking changes
- [ ] Examples are tested and working
- [ ] Platform-specific considerations are documented

### Community Gates
- [ ] Open issues have been triaged
- [ ] Community feedback has been addressed
- [ ] Breaking changes have been discussed with users
- [ ] Deprecation warnings have been in place for appropriate time

## Rollback Plan

If issues are discovered after release:

1. **Immediate Response**
   - [ ] Assess severity of the issue
   - [ ] Determine if rollback is necessary
   - [ ] Communicate with users via GitHub and pub.dev

2. **Rollback Process**
   - [ ] Retract the problematic version (if possible)
   - [ ] Release a fixed version immediately
   - [ ] Update documentation with workarounds
   - [ ] Notify users of the issue and resolution

3. **Post-Mortem**
   - [ ] Analyze what went wrong
   - [ ] Update testing procedures to prevent recurrence
   - [ ] Improve CI/CD pipeline if necessary
   - [ ] Document lessons learned

## Release Communication

### Internal Communication
- [ ] Notify maintainers of pending release
- [ ] Coordinate with dependent project maintainers
- [ ] Update internal tracking systems

### External Communication
- [ ] Prepare release notes for GitHub
- [ ] Update social media accounts (if applicable)
- [ ] Notify Flutter community channels
- [ ] Update blog posts or articles (if applicable)

### User Communication
- [ ] Clear migration instructions for breaking changes
- [ ] Highlight new features and improvements
- [ ] Provide troubleshooting information
- [ ] Include performance improvements and metrics
