package com.hangzhouchuda.huahuoai

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object HomeWidgetBridge {
    internal const val PREFERENCES_NAME = "huahuoai.home_widgets.v1"
    internal const val KEY_AUTHENTICATED = "snapshot.authenticated"
    internal const val KEY_PERSONAL_CONTENT = "snapshot.personal_content"
    internal const val KEY_DEPOSITED_CONTENT = "snapshot.deposited_content"
    internal const val KEY_LEVEL = "snapshot.level"
    internal const val KEY_LEVEL_SPAN = "snapshot.level_span"
    internal const val KEY_RECORDING_ACTION_TOKEN = "snapshot.recording_action_token"
    internal const val KEY_POINTS_IN_LEVEL = "snapshot.points_in_level"
    internal const val KEY_RECORDING_STATE = "snapshot.recording_state"
    internal const val KEY_RECORDING_BATTERY = "snapshot.recording_battery"
    internal const val KEY_RECORDING_ELAPSED = "snapshot.recording_elapsed"
    internal const val KEY_UPDATED_AT = "snapshot.updated_at_epoch_ms"

    private const val CHANNEL_NAME = "huahuoai/home_widgets"
    private var channel: MethodChannel? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        unregister()
        channel = MethodChannel(messenger, CHANNEL_NAME).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                handle(context.applicationContext, call, result)
            }
        }
    }

    fun unregister() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun handle(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (call.method != "updateSnapshot") {
            result.notImplemented()
            return
        }
        val snapshot = SafeHomeWidgetSnapshot.parse(call.arguments)
        if (snapshot == null) {
            result.error(
                "HOME_WIDGET_SNAPSHOT_INVALID",
                "Home widget snapshot is invalid.",
                null,
            )
            return
        }
        val editor = context
            .getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_AUTHENTICATED, snapshot.isAuthenticated)
            .putInt(KEY_PERSONAL_CONTENT, snapshot.personalContentCount)
            .putInt(KEY_DEPOSITED_CONTENT, snapshot.depositedContentCount)
            .putInt(KEY_LEVEL, snapshot.level)
            .putInt(KEY_POINTS_IN_LEVEL, snapshot.pointsInLevel)
            .putString(KEY_RECORDING_STATE, snapshot.recordingState)
            .putInt(KEY_RECORDING_ELAPSED, snapshot.recordingElapsedSeconds)
            .putLong(KEY_UPDATED_AT, snapshot.updatedAtEpochMs)
        if (snapshot.levelSpan == null) editor.remove(KEY_LEVEL_SPAN)
        else editor.putInt(KEY_LEVEL_SPAN, snapshot.levelSpan)
        if (snapshot.recordingActionToken == null) editor.remove(KEY_RECORDING_ACTION_TOKEN)
        else editor.putString(KEY_RECORDING_ACTION_TOKEN, snapshot.recordingActionToken)
        val battery = snapshot.recordingCardBatteryPercent
        if (battery == null) {
            editor.remove(KEY_RECORDING_BATTERY)
        } else {
            editor.putInt(KEY_RECORDING_BATTERY, battery)
        }
        if (!editor.commit()) {
            result.error("HOME_WIDGET_SAVE_FAILED", "Home widget snapshot could not be saved.", null)
            return
        }
        HuahuoAppWidgets.refreshAll(context)
        result.success(true)
    }
}

private data class SafeHomeWidgetSnapshot(
    val isAuthenticated: Boolean,
    val personalContentCount: Int,
    val depositedContentCount: Int,
    val level: Int,
    val pointsInLevel: Int,
    val levelSpan: Int?,
    val recordingActionToken: String?,
    val recordingState: String,
    val recordingElapsedSeconds: Int,
    val recordingCardBatteryPercent: Int?,
    val updatedAtEpochMs: Long,
) {
    companion object {
        private val allowedKeys = setOf(
            "schemaVersion",
            "isAuthenticated",
            "personalContentCount",
            "depositedContentCount",
            "level",
            "pointsInLevel",
            "levelSpan",
            "recordingActionToken",
            "recordingState",
            "recordingElapsedSeconds",
            "recordingCardBatteryPercent",
            "updatedAtEpochMs",
        )

        fun parse(raw: Any?): SafeHomeWidgetSnapshot? {
            val values = raw as? Map<*, *> ?: return null
            if (values.keys.any { it !is String || it !in allowedKeys }) return null
            val version = values.int("schemaVersion")
            if (version != 2 && version != 3) return null
            val authenticated = values["isAuthenticated"] as? Boolean ?: return null
            val personal = values.int("personalContentCount") ?: return null
            val deposited = values.int("depositedContentCount") ?: return null
            val level = values.int("level") ?: return null
            val points = values.int("pointsInLevel") ?: return null
            val recordingState = values["recordingState"] as? String ?: return null
            val recordingElapsed = values.int("recordingElapsedSeconds") ?: return null
            val battery = values.optionalInt("recordingCardBatteryPercent") ?: return null
            val updatedAt = values.long("updatedAtEpochMs") ?: return null
            if (personal !in 0..1_000_000 || deposited !in 0..1_000_000) return null
            if (level !in 1..10 || points !in 0..1_000_000) return null
            val span = if (version == 3) values.int("levelSpan") ?: return null else null
            if (span != null && ((if (level == 10) span != 0 else span !in 1..1_000_000) ||
                    points > span || (!authenticated && span != 1))) return null
            if (version == 2 && points > 100) return null
            val token = if (version == 3) values["recordingActionToken"] as? String else null
            if (version == 3 && values.containsKey("recordingActionToken") &&
                (token == null || !token.matches(Regex("^[a-f0-9]{64}$")) ||
                    !authenticated || recordingState == "disconnected")) return null
            if (recordingState !in setOf("disconnected", "idle", "recording", "paused")) {
                return null
            }
            if (recordingElapsed !in 0..86_400_000) return null
            if (battery.value != null && battery.value !in 0..100) return null
            if (recordingState == "disconnected" &&
                (battery.value != null || recordingElapsed != 0)
            ) return null
            if (updatedAt <= 0) return null
            if (!authenticated &&
                (personal != 0 || deposited != 0 || level != 1 || points != 0 ||
                    recordingState != "disconnected" || battery.value != null)
            ) {
                return null
            }
            return SafeHomeWidgetSnapshot(
                isAuthenticated = authenticated,
                personalContentCount = personal,
                depositedContentCount = deposited,
                level = level,
                pointsInLevel = points,
                levelSpan = span,
                recordingActionToken = token,
                recordingState = recordingState,
                recordingElapsedSeconds = recordingElapsed,
                recordingCardBatteryPercent = battery.value,
                updatedAtEpochMs = updatedAt,
            )
        }
    }
}

private data class OptionalInt(val value: Int?)

private fun Map<*, *>.int(key: String): Int? {
    val long = long(key) ?: return null
    return if (long in Int.MIN_VALUE..Int.MAX_VALUE) long.toInt() else null
}

private fun Map<*, *>.long(key: String): Long? = when (val value = this[key]) {
    is Int -> value.toLong()
    is Long -> value
    else -> null
}

private fun Map<*, *>.optionalInt(key: String): OptionalInt? {
    if (!containsKey(key)) return OptionalInt(null)
    return OptionalInt(int(key) ?: return null)
}
