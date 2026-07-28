// Copyright © 2023 Middleware. Licensed under the Apache License, Version 2.0

import Flutter
import MiddlewareRum
import UIKit

/// Thin bridge over the stable MiddlewareRum iOS SDK.
///
/// The Dart layer owns tracing (spans export via OTLP directly from Dart),
/// the session id (pushed via setSessionId -> MiddlewareRum.setNativeSession),
/// and screen names (pushed via setScreenName). The native SDK provides crash
/// reporting and the v3 session recording, which follow the injected session
/// and screen names.
public class MiddlewareFlutterPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "middleware_flutter_opentelemetry",
            binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(MiddlewareFlutterPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initNativeSdk":
            initNativeSdk(call.arguments as? [String: Any] ?? [:], result)

        case "setSessionId":
            guard let args = call.arguments as? [String: Any],
                  let sessionId = args["sessionId"] as? String,
                  let startTimeMs = args["startTimeMs"] as? NSNumber else {
                result(FlutterError(code: "MW_ARGS", message: "setSessionId: sessionId/startTimeMs missing", details: nil))
                return
            }
            MiddlewareRum.setNativeSession(sessionId, startTimeMs: startTimeMs.doubleValue)
            result(true)

        case "setScreenName":
            if let name = call.arguments as? String {
                // setScreenName is main-thread guarded in the native SDK.
                DispatchQueue.main.async {
                    MiddlewareRum.setScreenName(name)
                }
            }
            result(true)

        case "nativeCrash":
            result(true)
            let values: [Int] = []
            _ = values[7] // deliberate out-of-bounds crash for testing

        case "nativeAnr":
            // ANR reporting is Android-only; keep the method safe to call.
            result(true)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func initNativeSdk(_ config: [String: Any], _ result: @escaping FlutterResult) {
        guard let target = config["target"] as? String,
              let accountKey = config["accountKey"] as? String,
              let serviceName = config["serviceName"] as? String,
              let projectName = config["projectName"] as? String else {
            result(FlutterError(code: "MW_INIT",
                                message: "initNativeSdk: target/accountKey/serviceName/projectName missing",
                                details: nil))
            return
        }

        let builder = MiddlewareRumBuilder()
            .target(target)
            .rumAccessToken(accountKey)
            .serviceName(serviceName)
            .projectName(projectName)
            // Dart owns app-start/screen tracking and tap capture; native
            // crash/network/slow-rendering/v3-recording stay on.
            .disableUIInstrumentation()
            .disableAppLifcycleInstrumentation()

        if let environment = config["deploymentEnvironment"] as? String {
            _ = builder.deploymentEnvironment(environment)
        }
        var globalAttributes = (config["globalAttributes"] as? [String: Any]) ?? [:]
        if let resourceAttributes = config["resourceAttributes"] as? [String: Any] {
            globalAttributes.merge(resourceAttributes) { current, _ in current }
        }
        if !globalAttributes.isEmpty {
            _ = builder.globalAttributes(globalAttributes)
        }
        if let ratio = config["sessionSamplingRatio"] as? Double {
            _ = builder.sessionSamplingRatio(samplingRatio: ratio)
        }
        if (config["sessionRecording"] as? Bool) != true {
            _ = builder.disableRecording()
        }
        if config["disableSessionRecordingV3"] as? Bool == true {
            _ = builder.disableSessionRecordingV3()
        }
        if let recordingOptions = config["recordingOptions"] as? [String: Any] {
            _ = builder.recordingOptions(mapRecordingOptions(recordingOptions))
        }

        // Inject the Dart-owned session BEFORE build() so the native SDK never
        // creates its own session (which would surface as a phantom session
        // holding the pre-injection native telemetry).
        if let sessionId = config["sessionId"] as? String,
           let startTimeMs = config["sessionStartTimeMs"] as? NSNumber {
            MiddlewareRum.setNativeSession(sessionId, startTimeMs: startTimeMs.doubleValue)
        }

        // v3 session recording starts inside build() (sampler-gated).
        let initialized = builder.build()

        result([
            "initialized": initialized,
            "appVersion": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            "osVersion": UIDevice.current.systemVersion,
            "deviceModel": UIDevice.current.model,
        ] as [String: Any])
    }

    private func mapRecordingOptions(_ map: [String: Any]) -> RecordingOptions {
        let options = RecordingOptions()
        switch (map["frequency"] as? String)?.lowercased() {
        case "high": options.setFrequency(.high)
        case "standard": options.setFrequency(.standard)
        case "low": options.setFrequency(.low)
        default: break
        }
        switch (map["quality"] as? String)?.lowercased() {
        case "high": options.setQuality(.High)
        case "standard": options.setQuality(.Standard)
        case "low": options.setQuality(.Low)
        default: break
        }
        if let mask = map["maskAllTextInputs"] as? Bool {
            options.setMaskAllTextInputs(mask)
        }
        if let mask = map["maskAllImages"] as? Bool {
            options.setMaskAllImages(mask)
        }
        return options
    }
}
