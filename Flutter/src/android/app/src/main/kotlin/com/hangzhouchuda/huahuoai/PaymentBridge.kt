package com.hangzhouchuda.huahuoai

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object PaymentBridge {
    private const val METHOD_CHANNEL = "huahuoai/payment"
    private const val EVENT_CHANNEL = "huahuoai/payment/events"
    private const val WECHAT_PACKAGE = "com.tencent.mm"
    private const val ALIPAY_PACKAGE = "com.eg.android.AlipayGphone"

    private var activity: Activity? = null
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null

    fun register(activity: Activity, messenger: BinaryMessenger) {
        unregister()
        this.activity = activity
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also { channel ->
            channel.setMethodCallHandler(::handleMethodCall)
        }
        eventChannel = EventChannel(messenger, EVENT_CHANNEL).also { channel ->
            channel.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }
    }

    fun unregister() {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        eventSink = null
        activity = null
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isWechatInstalled" -> result.success(isPackageAvailable(WECHAT_PACKAGE))
            "isAlipayAvailable" -> result.success(isPackageAvailable(ALIPAY_PACKAGE))
            "startWechatPay" -> rejectUnconfiguredStart(call, result, "wechat")
            "startAlipayPay" -> rejectUnconfiguredStart(call, result, "alipay")
            else -> result.notImplemented()
        }
    }

    private fun rejectUnconfiguredStart(
        call: MethodCall,
        result: MethodChannel.Result,
        provider: String,
    ) {
        val arguments = call.arguments as? Map<*, *>
        val orderId = arguments?.get("orderId") as? String
        if (!PaymentContract.validOrderId(orderId)) {
            result.error("PAYMENT_REQUEST_INVALID", "Payment order identifier is invalid.", null)
            return
        }
        // The reviewed fixed-version Provider SDK is intentionally required
        // before launch. Never turn an Intent return into payment success.
        result.error(
            "PAYMENT_PROVIDER_NOT_CONFIGURED",
            "$provider payment SDK is not configured in this build.",
            null,
        )
    }

    @Suppress("DEPRECATION")
    private fun isPackageAvailable(packageName: String): Boolean {
        val current = activity ?: return false
        return runCatching {
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                current.packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                current.packageManager.getPackageInfo(packageName, 0)
            }
            val launchIntent: Intent? = current.packageManager.getLaunchIntentForPackage(packageName)
            launchIntent != null
        }.getOrDefault(false)
    }
}
