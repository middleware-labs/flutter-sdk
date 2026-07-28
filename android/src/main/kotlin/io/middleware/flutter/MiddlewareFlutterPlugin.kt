// Copyright © 2023 Middleware. Licensed under the Apache License, Version 2.0

package io.middleware.flutter

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.middleware.android.sdk.Middleware
import io.middleware.android.sdk.builders.MiddlewareBuilder
import io.middleware.android.sdk.core.replay.RecordingFrequency
import io.middleware.android.sdk.core.replay.RecordingQuality
import io.middleware.android.sdk.core.replay.v2.RecordingOptions
import io.opentelemetry.api.common.AttributeKey
import io.opentelemetry.api.common.Attributes
import io.opentelemetry.api.common.AttributesBuilder

/**
 * Thin bridge over the stable Middleware Android SDK.
 *
 * The Dart layer owns tracing (spans export via OTLP directly from Dart),
 * the session id (pushed via setSessionId -> Middleware.setNativeSession),
 * and screen names (pushed via setScreenName). The native SDK provides
 * crash/ANR reporting, network monitoring, slow rendering, and the v3
 * session recording (which follows the injected session and screen names).
 */
class MiddlewareFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var applicationContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "middleware_flutter_opentelemetry")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        applicationContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initNativeSdk" -> {
                @Suppress("UNCHECKED_CAST")
                initNativeSdk(call.arguments as? Map<String, Any?> ?: emptyMap(), result)
            }

            "setSessionId" -> {
                val sessionId = call.argument<String>("sessionId")
                val startTimeMs = call.argument<Number>("startTimeMs")
                if (sessionId == null || startTimeMs == null) {
                    result.error("MW_ARGS", "setSessionId: sessionId/startTimeMs missing", null)
                    return
                }
                // Round like the other bridges; never String.valueOf(double)
                // (large millis render as scientific notation).
                val startMsStr = Math.round(startTimeMs.toDouble()).toString()
                Middleware.getInstance().apply {
                    setGlobalAttribute(AttributeKey.stringKey("session.id"), sessionId)
                    setGlobalAttribute(AttributeKey.stringKey("session.start_time"), startMsStr)
                    setNativeSession(sessionId, startMsStr)
                }
                result.success(true)
            }

            "setScreenName" -> {
                val name = call.arguments as? String
                if (name != null) {
                    // NoOpMiddleware makes this safe before initNativeSdk.
                    Middleware.getInstance().setScreenName(name)
                }
                result.success(true)
            }

            "nativeCrash" -> {
                Thread {
                    try {
                        Thread.sleep(2000)
                    } catch (ignored: InterruptedException) {
                    }
                    throw RuntimeException("test crash")
                }.start()
                result.success(true)
            }

            "nativeAnr" -> {
                Handler(Looper.getMainLooper()).post {
                    try {
                        Thread.sleep(25_000)
                    } catch (ignored: InterruptedException) {
                    }
                }
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun initNativeSdk(config: Map<String, Any?>, result: MethodChannel.Result) {
        val application = applicationContext?.applicationContext as? Application
        if (application == null) {
            result.error("MW_INIT", "initNativeSdk: no Application context", null)
            return
        }
        val target = config["target"] as? String
        val accountKey = config["accountKey"] as? String
        val serviceName = config["serviceName"] as? String
        val projectName = config["projectName"] as? String
        if (target == null || accountKey == null || serviceName == null || projectName == null) {
            result.error("MW_INIT", "initNativeSdk: target/accountKey/serviceName/projectName missing", null)
            return
        }

        val builder: MiddlewareBuilder = Middleware.builder()
            .setTarget(target)
            .setRumAccessToken(accountKey)
            .setServiceName(serviceName)
            .setProjectName(projectName)
            // Dart owns app-start/screen tracking and tap capture; native
            // crash/ANR/network/slow-rendering/v3-recording stay on.
            .disableActivityLifecycleMonitoring()
            .disableUIInstrumentation()

        (config["deploymentEnvironment"] as? String)?.let { builder.setDeploymentEnvironment(it) }
        attributesFrom(config["resourceAttributes"])?.let { builder.setResourceAttributes(it) }
        attributesFrom(config["globalAttributes"])?.let { builder.setGlobalAttributes(it) }
        if (config["sessionRecording"] != true) {
            builder.disableSessionRecording()
        }
        if (config["disableSessionRecordingV3"] == true) {
            builder.disableSessionRecordingV3()
        }
        (config["sessionSamplingRatio"] as? Number)?.let { builder.setSessionSamplingRatio(it.toDouble()) }
        @Suppress("UNCHECKED_CAST")
        (config["recordingOptions"] as? Map<String, Any?>)?.let {
            builder.setRecordingOptions(recordingOptionsFrom(it))
        }

        // v3 session recording starts inside build() (sampler-gated).
        // Middleware.initialize is singleton-guarded, so hot restart is safe.
        builder.build(application)

        // Link the Dart-owned session immediately, before the v3 recorder
        // captures its first frame, so no telemetry lands under the native
        // auto-generated session.
        val sessionId = config["sessionId"] as? String
        val sessionStartTimeMs = config["sessionStartTimeMs"] as? Number
        if (sessionId != null && sessionStartTimeMs != null) {
            val startMsStr = Math.round(sessionStartTimeMs.toDouble()).toString()
            Middleware.getInstance().apply {
                setGlobalAttribute(AttributeKey.stringKey("session.id"), sessionId)
                setGlobalAttribute(AttributeKey.stringKey("session.start_time"), startMsStr)
                setNativeSession(sessionId, startMsStr)
            }
        }

        result.success(
            mapOf(
                "initialized" to Middleware.isInitialized(),
                "appVersion" to appVersion(application),
                "osVersion" to android.os.Build.VERSION.RELEASE,
                "deviceModel" to android.os.Build.MODEL,
            )
        )
    }

    private fun recordingOptionsFrom(map: Map<String, Any?>): RecordingOptions {
        val options = RecordingOptions.Builder()
        when ((map["frequency"] as? String)?.lowercase()) {
            "high" -> options.setFrequency(RecordingFrequency.HIGH)
            "standard" -> options.setFrequency(RecordingFrequency.STANDARD)
            "low" -> options.setFrequency(RecordingFrequency.LOW)
        }
        when ((map["quality"] as? String)?.lowercase()) {
            "high" -> options.setQuality(RecordingQuality.HIGH)
            "standard" -> options.setQuality(RecordingQuality.MEDIUM)
            "low" -> options.setQuality(RecordingQuality.LOW)
        }
        (map["maskAllTextInputs"] as? Boolean)?.let { options.setMaskAllTextInputs(it) }
        (map["maskAllImages"] as? Boolean)?.let { options.setMaskAllImages(it) }
        return options.build()
    }

    private fun attributesFrom(raw: Any?): Attributes? {
        @Suppress("UNCHECKED_CAST")
        val map = raw as? Map<String, Any?> ?: return null
        if (map.isEmpty()) return null
        val builder: AttributesBuilder = Attributes.builder()
        for ((key, value) in map) {
            when (value) {
                is String -> builder.put(key, value)
                is Boolean -> builder.put(key, value)
                is Int -> builder.put(key, value.toLong())
                is Long -> builder.put(key, value)
                is Double -> builder.put(key, value)
            }
        }
        return builder.build()
    }

    private fun appVersion(application: Application): String {
        return try {
            application.packageManager
                .getPackageInfo(application.packageName, 0)
                .versionName ?: "unknown"
        } catch (e: Exception) {
            "unknown"
        }
    }
}
