package com.hangzhouchuda.huahuoai

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build

object HuahuoNotificationChannels {
    const val TASK_RESULTS = "huahuo_task_results"
    const val ATTENTION_REQUIRED = "huahuo_attention_required"
    const val GENERAL = "huahuo_general"

    fun create(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannels(
            listOf(
                NotificationChannel(
                    TASK_RESULTS,
                    "任务完成",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "录音转写、内容生成和分析完成提醒"
                    enableVibration(true)
                },
                NotificationChannel(
                    ATTENTION_REQUIRED,
                    "需要处理",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "任务失败、额度不足和需要用户处理的提醒"
                    enableVibration(true)
                },
                NotificationChannel(
                    GENERAL,
                    "一般消息",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "一般状态和内容更新提醒"
                },
            ),
        )
    }
}
