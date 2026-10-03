package com.hangzhouchuda.huahuoai

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import android.util.TypedValue

object HuahuoAppWidgets {
    private val providers = listOf(
        HuahuoQuickActionsWidget::class.java,
        HuahuoRecordingCardWidget::class.java,
        HuahuoAssetsWidget::class.java,
    )

    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        providers.forEach { provider ->
            val ids = manager.getAppWidgetIds(ComponentName(context, provider))
            if (ids.isNotEmpty()) {
                val intent = Intent(context, provider).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                }
                context.sendBroadcast(intent)
            }
        }
    }
}

class HuahuoQuickActionsWidget : HuahuoWidgetProvider(WidgetKind.QUICK)

class HuahuoRecordingCardWidget : HuahuoWidgetProvider(WidgetKind.RECORDING)

class HuahuoAssetsWidget : HuahuoWidgetProvider(WidgetKind.ASSETS)

abstract class HuahuoWidgetProvider(
    private val kind: WidgetKind,
) : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val snapshot = AndroidHomeWidgetSnapshot.read(context)
        appWidgetIds.forEach { widgetId ->
            appWidgetManager.updateAppWidget(
                widgetId,
                render(context, widgetId, kind, snapshot),
            )
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(
            context,
            appWidgetManager,
            appWidgetId,
            newOptions,
        )
        appWidgetManager.updateAppWidget(
            appWidgetId,
            render(
                context,
                appWidgetId,
                kind,
                AndroidHomeWidgetSnapshot.read(context),
            ),
        )
    }
}

enum class WidgetKind { QUICK, RECORDING, ASSETS }

private data class AndroidHomeWidgetSnapshot(
    val authenticated: Boolean,
    val personalContentCount: Int,
    val depositedContentCount: Int,
    val level: Int,
    val pointsInLevel: Int,
    val recordingConnected: Boolean,
    val recordingState: String,
    val recordingElapsedSeconds: Int,
    val updatedAtEpochMs: Long,
    val recordingBatteryPercent: Int?,
    val levelSpan: Int? = null,
    val recordingActionToken: String? = null,
) {
    companion object {
        fun read(context: Context): AndroidHomeWidgetSnapshot {
            val preferences = context.getSharedPreferences(
                HomeWidgetBridge.PREFERENCES_NAME,
                Context.MODE_PRIVATE,
            )
            val authenticated = preferences.getBoolean(
                HomeWidgetBridge.KEY_AUTHENTICATED,
                false,
            )
            if (!authenticated) {
                return AndroidHomeWidgetSnapshot(
                    authenticated = false,
                    personalContentCount = 0,
                    depositedContentCount = 0,
                    level = 1,
                    pointsInLevel = 0,
                    recordingConnected = false,
                    recordingState = "disconnected",
                    recordingElapsedSeconds = 0,
                    updatedAtEpochMs = 0,
                    recordingBatteryPercent = null,
                )
            }
            val storedState = preferences.getString(
                HomeWidgetBridge.KEY_RECORDING_STATE,
                "disconnected",
            ) ?: "disconnected"
            val updatedAt = preferences.getLong(HomeWidgetBridge.KEY_UPDATED_AT, 0)
            val age = System.currentTimeMillis() - updatedAt
            val knownState = storedState in setOf("disconnected", "idle", "recording", "paused")
            val recordingState = if (!knownState ||
                (storedState != "disconnected" && (age < 0 || age >= 1_800_000L))
            ) "stale" else storedState
            val connected = recordingState in setOf("idle", "recording", "paused")
            val span = if (preferences.contains(HomeWidgetBridge.KEY_LEVEL_SPAN))
                preferences.getInt(HomeWidgetBridge.KEY_LEVEL_SPAN, -1).takeIf { it in 0..1_000_000 }
                else null
            val token = preferences.getString(HomeWidgetBridge.KEY_RECORDING_ACTION_TOKEN, null)
                ?.takeIf { connected && it.matches(Regex("^[a-f0-9]{64}$")) }
            return AndroidHomeWidgetSnapshot(
                levelSpan = span,
                recordingActionToken = token,
                authenticated = true,
                personalContentCount = preferences.getInt(
                    HomeWidgetBridge.KEY_PERSONAL_CONTENT,
                    0,
                ).coerceIn(0, 1_000_000),
                depositedContentCount = preferences.getInt(
                    HomeWidgetBridge.KEY_DEPOSITED_CONTENT,
                    0,
                ).coerceIn(0, 1_000_000),
                level = preferences.getInt(HomeWidgetBridge.KEY_LEVEL, 1)
                    .coerceIn(1, 10),
                pointsInLevel = preferences.getInt(
                    HomeWidgetBridge.KEY_POINTS_IN_LEVEL,
                    0,
                ).coerceIn(0, span ?: 0),
                recordingConnected = connected,
                recordingState = recordingState,
                recordingElapsedSeconds = preferences.getInt(
                    HomeWidgetBridge.KEY_RECORDING_ELAPSED,
                    0,
                ).coerceIn(0, 86_400_000),
                updatedAtEpochMs = preferences.getLong(
                    HomeWidgetBridge.KEY_UPDATED_AT,
                    0,
                ),
                recordingBatteryPercent = if (
                    connected && preferences.contains(HomeWidgetBridge.KEY_RECORDING_BATTERY)
                ) {
                    preferences.getInt(HomeWidgetBridge.KEY_RECORDING_BATTERY, 0)
                        .coerceIn(0, 100)
                } else {
                    null
                },
            )
        }
    }
}

private fun render(
    context: Context,
    widgetId: Int,
    kind: WidgetKind,
    snapshot: AndroidHomeWidgetSnapshot,
): RemoteViews {
    val views = RemoteViews(context.packageName, R.layout.home_widget_shell)
    views.setOnClickPendingIntent(
        R.id.widget_root,
        deepLink(context, widgetId * 10, "/v3/feed"),
    )
    when (kind) {
        WidgetKind.QUICK -> renderQuick(context, views, widgetId)
        WidgetKind.RECORDING -> renderRecording(context, views, widgetId, snapshot)
        WidgetKind.ASSETS -> renderAssets(context, views, widgetId, snapshot)
    }
    val options = AppWidgetManager.getInstance(context).getAppWidgetOptions(widgetId)
    val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 180)
    val compact = height < 165 || context.resources.configuration.fontScale >= 1.3f
    if (compact) {
        views.setViewVisibility(R.id.widget_brand, View.GONE)
        views.setViewVisibility(R.id.widget_secondary_detail, View.GONE)
        views.setTextViewTextSize(R.id.widget_title, TypedValue.COMPLEX_UNIT_SP, 14f)
        views.setTextViewTextSize(R.id.widget_primary_detail, TypedValue.COMPLEX_UNIT_SP, 11f)
    }
    if (height < 140) views.setViewVisibility(R.id.widget_recording_elapsed, View.GONE)
    return views
}

private fun renderQuick(context: Context, views: RemoteViews, widgetId: Int) {
    views.setViewVisibility(R.id.widget_recording_elapsed, View.GONE)
    views.setTextViewText(R.id.widget_title, "快速开始")
    views.setTextViewText(R.id.widget_primary_detail, "捕捉想法，继续创作")
    views.setViewVisibility(R.id.widget_secondary_detail, View.GONE)
    views.setTextViewText(R.id.widget_primary_action, "自由创作")
    views.setTextViewText(R.id.widget_secondary_action, "记笔记")
    views.setViewVisibility(R.id.widget_secondary_action, View.VISIBLE)
    views.setOnClickPendingIntent(
        R.id.widget_primary_action,
        deepLink(context, widgetId * 10 + 1, "/v3/workbench/canvas"),
    )
    views.setOnClickPendingIntent(
        R.id.widget_secondary_action,
        deepLink(context, widgetId * 10 + 2, "/v3/feed/note"),
    )
}

private fun renderRecording(
    context: Context,
    views: RemoteViews,
    widgetId: Int,
    snapshot: AndroidHomeWidgetSnapshot,
) {
    views.setOnClickPendingIntent(
        R.id.widget_root,
        deepLink(context, widgetId * 10, "/v3/recording-card/control"),
    )
    views.setTextViewText(R.id.widget_title, "录音卡")
    val primary = when {
        !snapshot.authenticated -> "登录后查看设备状态"
        snapshot.recordingState == "stale" -> "状态待刷新"
        snapshot.recordingState == "recording" -> "上次同步 · 录音中"
        snapshot.recordingState == "paused" -> "上次同步 · 已暂停"
        snapshot.recordingConnected -> "上次同步 · 待机"
        else -> "未连接"
    }
    val secondary = when {
        snapshot.recordingState == "stale" -> "打开 App 确认录音卡状态"
        snapshot.recordingConnected && snapshot.recordingBatteryPercent != null ->
            "电量 ${snapshot.recordingBatteryPercent}%"
        snapshot.recordingConnected -> "电量 --"
        else -> "打开 App 连接录音卡"
    }
    views.setTextViewText(R.id.widget_primary_detail, primary)
    views.setTextViewText(R.id.widget_secondary_detail, secondary)
    views.setViewVisibility(R.id.widget_secondary_detail, View.VISIBLE)
    if (snapshot.recordingConnected) {
        val wallDeltaSeconds = if (snapshot.recordingState == "recording") {
            ((System.currentTimeMillis() - snapshot.updatedAtEpochMs) / 1000L)
                .coerceAtLeast(0L)
        } else {
            0L
        }
        val elapsed = (snapshot.recordingElapsedSeconds.toLong() + wallDeltaSeconds)
            .coerceAtMost(86_400_000L)
        views.setChronometer(
            R.id.widget_recording_elapsed,
            SystemClock.elapsedRealtime() - elapsed * 1000L,
            "%s",
            snapshot.recordingState == "recording",
        )
        views.setViewVisibility(R.id.widget_recording_elapsed, View.VISIBLE)
    } else {
        views.setViewVisibility(R.id.widget_recording_elapsed, View.GONE)
    }
    val action = if (snapshot.recordingConnected && snapshot.recordingActionToken == null) "refresh" else when (snapshot.recordingState) {
        "idle" -> "start"
        "recording" -> "pause"
        "paused" -> "resume"
        "stale" -> "refresh"
        else -> "connect"
    }
    val actionLabel = when (action) {
        "start" -> "开始"
        "pause" -> "暂停"
        "resume" -> "继续"
        "refresh" -> "刷新状态"
        else -> "连接录音卡"
    }
    views.setTextViewText(R.id.widget_primary_action, actionLabel)
    views.setTextViewText(R.id.widget_secondary_action, "设备管理")
    views.setViewVisibility(R.id.widget_secondary_action, View.VISIBLE)
    views.setOnClickPendingIntent(
        R.id.widget_primary_action,
        deepLink(
            context,
            widgetId * 10 + 3,
            "/v3/recording-card/control?widgetAction=$action&widgetRevision=${snapshot.updatedAtEpochMs}&widgetToken=${snapshot.recordingActionToken ?: ""}",
        ),
    )
    views.setOnClickPendingIntent(
        R.id.widget_secondary_action,
        deepLink(context, widgetId * 10 + 6, "/v3/recording-card"),
    )
}

private fun renderAssets(
    context: Context,
    views: RemoteViews,
    widgetId: Int,
    snapshot: AndroidHomeWidgetSnapshot,
) {
    views.setViewVisibility(R.id.widget_recording_elapsed, View.GONE)
    views.setTextViewText(R.id.widget_title, "成长与资产")
    if (snapshot.authenticated) {
        val growth = when (snapshot.levelSpan) {
            null -> "成长数据待更新"
            0 -> if (snapshot.level == 10) "已达最高等级" else "成长数据待更新"
            else -> "本级 ${snapshot.pointsInLevel}/${snapshot.levelSpan}"
        }
        views.setTextViewText(
            R.id.widget_primary_detail,
            "Lv.${snapshot.level} · $growth",
        )
        views.setTextViewText(
            R.id.widget_secondary_detail,
            "我的创建 ${snapshot.personalContentCount} · 已沉淀 ${snapshot.depositedContentCount}",
        )
    } else {
        views.setTextViewText(R.id.widget_primary_detail, "登录后查看成长进度")
        views.setTextViewText(R.id.widget_secondary_detail, "资产统计仅在本机显示")
    }
    views.setViewVisibility(R.id.widget_secondary_detail, View.VISIBLE)
    views.setTextViewText(R.id.widget_primary_action, "我的资产")
    views.setTextViewText(R.id.widget_secondary_action, "创作台")
    views.setViewVisibility(R.id.widget_secondary_action, View.VISIBLE)
    views.setOnClickPendingIntent(
        R.id.widget_primary_action,
        deepLink(context, widgetId * 10 + 4, "/v3/profile/assets"),
    )
    views.setOnClickPendingIntent(
        R.id.widget_secondary_action,
        deepLink(context, widgetId * 10 + 5, "/v3/workbench"),
    )
}

private fun deepLink(context: Context, requestCode: Int, route: String): PendingIntent {
    val intent = Intent(
        Intent.ACTION_VIEW,
        Uri.parse("huahuoai://$route"),
        context,
        MainActivity::class.java,
    ).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
    }
    return PendingIntent.getActivity(
        context,
        requestCode,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
