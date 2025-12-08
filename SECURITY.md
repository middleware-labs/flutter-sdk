# Security Policy

## Supported Versions

Below are the versions of the OpenTelemetry SDK for Flutter that are currently supported with security updates:

| Version | Supported          |
| ------- | ------------------ |
| 0.3.x   | :white_check_mark: |
| < 0.3.0 | :x:                |

## Reporting a Vulnerability

We take the security of OpenTelemetry SDK for Flutter seriously. If you believe you have found a security vulnerability, please follow these steps:

1. **Do not disclose the vulnerability publicly**
2. **Contact the maintainers privately** - Email security@middleware.io with details of the vulnerability
3. **Provide sufficient information** to reproduce the issue, including:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested mitigation if available
   - Flutter/Dart version and platform affected

## What to Expect

After you report a vulnerability:

1. **Acknowledgment** - You will receive acknowledgment of your report within 48 hours
2. **Verification** - Our team will work to verify the vulnerability
3. **Remediation Plan** - We will develop a plan to address the vulnerability
4. **Public Disclosure** - Once a fix is available, we will coordinate with you on public disclosure

## Security Best Practices

When using OpenTelemetry SDK for Flutter:

1. Keep the package updated to the latest supported version
2. Review your telemetry data to ensure sensitive information is not inadvertently collected
3. Apply appropriate access controls to your telemetry data collection endpoints
4. Consider using TLS for all telemetry data transmission
5. Implement appropriate sampling strategies to limit the volume of data collected
6. Configure span processors to handle data securely
7. Use secure connections for exporters that transmit data over the network
8. Be mindful of data collection in debug vs release builds

## Flutter-Specific Security Considerations

When implementing OpenTelemetry in Flutter applications:

1. **Platform Permissions**: Be aware of platform-specific permissions required for telemetry collection
2. **App Store Compliance**: Ensure telemetry collection complies with app store policies (Google Play, Apple App Store)
3. **Privacy Policies**: Update your app's privacy policy to reflect telemetry data collection
4. **User Consent**: Consider implementing user consent mechanisms for telemetry collection
5. **Debugging Data**: Avoid collecting sensitive debugging information in production builds
6. **Network Security**: Use secure connections (HTTPS/TLS) for all telemetry exports
7. **Local Storage**: If caching telemetry data locally, ensure proper encryption and secure storage

## Security Considerations for Telemetry Data

When implementing OpenTelemetry in Flutter apps:

1. **Data Minimization** - Only collect the telemetry data necessary for your use case
2. **PII Protection** - Avoid including personally identifiable information in spans or metrics
3. **Sensitive Data** - Avoid including sensitive information such as authentication tokens in attributes
4. **Network Security** - Use secure connections (TLS) when exporting telemetry data
5. **Authentication** - Consider using authentication for your OpenTelemetry Collector endpoints
6. **Access Control** - Implement appropriate access controls for your telemetry data
7. **Sanitization** - Consider implementing sanitization for sensitive attributes
8. **Sampling** - Use sampling to reduce the volume of potentially sensitive data
9. **User Data** - Be especially careful with user input data and form field values
10. **Device Information** - Consider privacy implications of collecting device identifiers

## Additional Flutter SDK-Specific Security Considerations

1. **Exporters**: Configure exporters to use secure connections (e.g., HTTPS, gRPC with TLS)
2. **Resource Attributes**: Be cautious about automatically adding device or environment information that might expose sensitive details
3. **Batch Processing**: Configure batch processors with appropriate queue sizes and timeouts to prevent memory exhaustion
4. **Error Handling**: Ensure that error handling in span processors doesn't leak sensitive information
5. **Configuration**: Securely manage any API keys or authentication tokens used in exporter configurations
6. **Widget Trees**: Avoid capturing sensitive widget state or user input in widget tracking
7. **Navigation Tracking**: Be mindful of sensitive route parameters when tracking navigation
8. **App Lifecycle**: Consider security implications of telemetry collection during app backgrounding/foregrounding
9. **Platform Channels**: Secure any platform-specific telemetry collection mechanisms
10. **Third-party Integrations**: Audit third-party packages used with the SDK for security vulnerabilities

## Mobile-Specific Security Considerations

1. **Certificate Pinning**: Consider implementing certificate pinning for telemetry endpoints
2. **Network Monitoring**: Be aware that mobile network traffic can be monitored on compromised devices
3. **App Sandboxing**: Leverage platform sandboxing to protect telemetry configuration and data
4. **Background Processing**: Secure telemetry processing when the app is in the background
5. **Memory Security**: Clear sensitive telemetry data from memory when appropriate

## Disclosure Policy

Our disclosure policy is:

1. Security issues will be announced via GitHub security advisories
2. CVEs will be requested when appropriate
3. Fixed versions will be clearly identified in release notes
4. Security patches will be prioritized over feature development
5. Users will be notified through pub.dev package updates and GitHub releases

## Security Updates

Security updates will be provided for:
- The current major version
- The previous major version (when applicable)
- Critical vulnerabilities may receive patches for older versions at maintainer discretion

## Reporting Security Issues in Dependencies

If you discover security issues in our dependencies (such as middleware_dart_opentelemetry or Flutter itself), please:
1. Report to the appropriate upstream project first
2. Notify our maintainers if the issue affects this package
3. We will coordinate with upstream maintainers for resolution
