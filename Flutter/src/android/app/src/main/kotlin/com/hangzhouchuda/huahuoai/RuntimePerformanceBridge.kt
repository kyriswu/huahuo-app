package com.hangzhouchuda.huahuoai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

internal class RuntimePerformanceBridge(
    private val context: Context,
    messenger: BinaryMessenger,
) {
    private val powerManager = context.getSystemService(PowerManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
    private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
    private var receiverRegistered = false
    private val powerSaveReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            emit()
        }
    }

    init {
        methodChannel.setMethodCallHandler { call, result ->
            if (call.method == "getState") result.success(snapshot()) else result.notImplemented()
        }
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                startObserving()
                emit()
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                stopObserving()
            }
        })
    }

    fun unregister() {
        eventSink = null
        stopObserving()
        eventChannel.setStreamHandler(null)
        methodChannel.setMethodCallHandler(null)
    }

    private fun startObserving() {
        if (!receiverRegistered) {
            val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(powerSaveReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                context.registerReceiver(powerSaveReceiver, filter)
            }
            receiverRegistered = true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && thermalListener == null) {
            val listener = PowerManager.OnThermalStatusChangedListener { emit() }
            thermalListener = listener
            powerManager.addThermalStatusListener(context.mainExecutor, listener)
        }
    }

    private fun stopObserving() {
        if (receiverRegistered) {
            runCatching { context.unregisterReceiver(powerSaveReceiver) }
            receiverRegistered = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            thermalListener?.let(powerManager::removeThermalStatusListener)
        }
        thermalListener = null
    }

    private fun emit() {
        mainHandler.post { eventSink?.success(snapshot()) }
    }

    private fun snapshot(): Map<String, Any> = mapOf(
        "thermal" to thermalToken(),
        "lowPower" to powerManager.isPowerSaveMode,
    )

    private fun thermalToken(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "unknown"
        return when (powerManager.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal"
            PowerManager.THERMAL_STATUS_LIGHT,
            PowerManager.THERMAL_STATUS_MODERATE,
            -> "fair"
            PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            PowerManager.THERMAL_STATUS_CRITICAL,
            PowerManager.THERMAL_STATUS_EMERGENCY,
            PowerManager.THERMAL_STATUS_SHUTDOWN,
            -> "critical"
            else -> "unknown"
        }
    }

    private companion object {
        const val METHOD_CHANNEL = "huahuoai/runtime_performance"
        const val EVENT_CHANNEL = "huahuoai/runtime_performance/events"
    }
}
