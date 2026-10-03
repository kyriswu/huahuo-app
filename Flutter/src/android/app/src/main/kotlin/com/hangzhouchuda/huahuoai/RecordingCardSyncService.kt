package com.hangzhouchuda.huahuoai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class RecordingCardSyncService : Service() {
    private var transferWakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val state = currentState()
        if (!RecordingCardSyncServiceContract.acceptsAction(intent?.action) ||
            !RecordingCardSyncServiceContract.shouldRun(state)
        ) {
            settle()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, notification(state))
        updateTransferWakeLock(state)
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        clearForStoppedService()
        settle()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseTransferWakeLock()
        super.onDestroy()
    }

    private fun updateTransferWakeLock(state: RecordingCardSyncServiceState) {
        if (!RecordingCardSyncServiceContract.shouldHoldWakeLock(state)) {
            releaseTransferWakeLock()
            return
        }
        val lock = transferWakeLock ?: getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "huahuoai:recording-card-transfer")
            .also { it.setReferenceCounted(false); transferWakeLock = it }
        if (!lock.isHeld) lock.acquire()
    }

    private fun releaseTransferWakeLock() {
        transferWakeLock?.let { lock ->
            if (lock.isHeld) runCatching { lock.release() }
        }
        transferWakeLock = null
    }

    private fun settle() {
        releaseTransferWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                RecordingCardSyncServiceContract.CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = RecordingCardSyncServiceContract.CHANNEL_DESCRIPTION
                setShowBadge(false)
            },
        )
    }

    private fun notification(state: RecordingCardSyncServiceState): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_huahuo)
            .setContentTitle(RecordingCardSyncServiceContract.notificationTitle(state))
            .setContentText(RecordingCardSyncServiceContract.notificationText(state))
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        @Volatile private var dartKeepAlive = false
        @Volatile private var dartTransferActive = false
        @Volatile private var dartTransferTransport: RecordingCardSyncTransport? = null
        @Volatile private var nativeWifiTransferActive = false

        @Synchronized
        fun setWifiTransferEnabled(context: Context, enabled: Boolean) {
            val previous = currentState()
            nativeWifiTransferActive = enabled
            try {
                updateService(context)
            } catch (failure: RuntimeException) {
                restoreState(previous)
                throw failure
            }
        }

        @Synchronized
        internal fun setExecutionState(
            context: Context,
            keepAlive: Boolean,
            transferActive: Boolean,
            transport: RecordingCardSyncTransport?,
        ): Map<String, Any> {
            val previous = currentState()
            dartKeepAlive = keepAlive
            dartTransferActive = transferActive
            dartTransferTransport = transport.takeIf { transferActive }
            try {
                updateService(context)
            } catch (failure: RuntimeException) {
                restoreState(previous)
                throw failure
            }
            return RecordingCardSyncServiceContract.capability(currentState().shouldRun)
        }

        @Synchronized
        fun setEnabled(context: Context, enabled: Boolean): Map<String, Any> =
            setExecutionState(
                context = context,
                keepAlive = enabled,
                transferActive = false,
                transport = null,
            )

        @Synchronized
        private fun currentState(): RecordingCardSyncServiceState =
            RecordingCardSyncServiceState(
                dartKeepAlive = dartKeepAlive,
                dartTransferActive = dartTransferActive,
                dartTransferTransport = dartTransferTransport,
                nativeWifiTransferActive = nativeWifiTransferActive,
            )

        private fun restoreState(state: RecordingCardSyncServiceState) {
            dartKeepAlive = state.dartKeepAlive
            dartTransferActive = state.dartTransferActive
            dartTransferTransport = state.dartTransferTransport
            nativeWifiTransferActive = state.nativeWifiTransferActive
        }

        private fun updateService(context: Context) {
            val intent = Intent(context, RecordingCardSyncService::class.java).apply {
                action = RecordingCardSyncServiceContract.ACTION_START
            }
            if (currentState().shouldRun) {
                ContextCompat.startForegroundService(context, intent)
            } else {
                context.stopService(intent)
            }
        }

        private const val CHANNEL_ID = "recording_card_auto_sync"
        private const val NOTIFICATION_ID = 0x524153

        @Synchronized
        fun stopForDetachedRuntime(context: Context) {
            clearForStoppedService()
            val intent = Intent(context, RecordingCardSyncService::class.java)
            context.stopService(intent)
        }

        @Synchronized
        private fun clearForStoppedService() {
            dartKeepAlive = false
            dartTransferActive = false
            dartTransferTransport = null
            nativeWifiTransferActive = false
        }
    }
}

internal enum class RecordingCardSyncTransport(val wireValue: String) {
    BLUETOOTH("bluetooth"),
    WIFI("wifi");

    companion object {
        fun fromWire(value: String?): RecordingCardSyncTransport? =
            entries.firstOrNull { it.wireValue == value }

        fun isValidWire(value: String?): Boolean =
            value == null || value == "none" || fromWire(value) != null
    }
}

internal data class RecordingCardSyncServiceState(
    val dartKeepAlive: Boolean,
    val dartTransferActive: Boolean,
    val dartTransferTransport: RecordingCardSyncTransport?,
    val nativeWifiTransferActive: Boolean,
) {
    val shouldRun: Boolean
        get() = dartKeepAlive || dartTransferActive || nativeWifiTransferActive

    val shouldHoldWakeLock: Boolean
        get() = dartTransferActive || nativeWifiTransferActive

    val effectiveTransferTransport: RecordingCardSyncTransport?
        get() = when {
            nativeWifiTransferActive -> RecordingCardSyncTransport.WIFI
            dartTransferActive -> dartTransferTransport
            else -> null
        }
}

internal object RecordingCardSyncServiceContract {
    const val ACTION_START = "huahuoai.recording_card.sync.START"
    const val ACTION_STOP = "huahuoai.recording_card.sync.STOP"
    const val MODE_PROCESS_BOUND = "processBound"
    const val CHANNEL_NAME = "录音卡后台连接"
    const val CHANNEL_DESCRIPTION = "保持录音卡状态监听与文件同步连接"
    const val MONITORING_NOTIFICATION_TITLE = "录音卡后台连接"
    const val MONITORING_NOTIFICATION_TEXT = "正在监听录音卡连接与录音状态"
    const val BLE_NOTIFICATION_TITLE = "正在通过蓝牙同步录音"
    const val BLE_NOTIFICATION_TEXT = "蓝牙文件传输将在后台继续"
    const val WIFI_NOTIFICATION_TITLE = "正在通过 WiFi 同步录音"
    const val WIFI_NOTIFICATION_TEXT = "WiFi 文件传输将在后台继续"
    const val TRANSFER_NOTIFICATION_TITLE = "正在同步录音卡文件"
    const val TRANSFER_NOTIFICATION_TEXT = "文件传输将在后台继续"

    fun acceptsAction(action: String?): Boolean = action == ACTION_START

    fun shouldRun(state: RecordingCardSyncServiceState): Boolean = state.shouldRun

    fun shouldHoldWakeLock(state: RecordingCardSyncServiceState): Boolean =
        state.shouldHoldWakeLock

    fun notificationTitle(state: RecordingCardSyncServiceState): String =
        when (state.effectiveTransferTransport) {
            RecordingCardSyncTransport.BLUETOOTH -> BLE_NOTIFICATION_TITLE
            RecordingCardSyncTransport.WIFI -> WIFI_NOTIFICATION_TITLE
            null -> if (state.dartTransferActive) {
                TRANSFER_NOTIFICATION_TITLE
            } else {
                MONITORING_NOTIFICATION_TITLE
            }
        }

    fun notificationText(state: RecordingCardSyncServiceState): String =
        when (state.effectiveTransferTransport) {
            RecordingCardSyncTransport.BLUETOOTH -> BLE_NOTIFICATION_TEXT
            RecordingCardSyncTransport.WIFI -> WIFI_NOTIFICATION_TEXT
            null -> if (state.dartTransferActive) {
                TRANSFER_NOTIFICATION_TEXT
            } else {
                MONITORING_NOTIFICATION_TEXT
            }
        }

    fun capability(enabled: Boolean): Map<String, Any> = mapOf(
        "mode" to MODE_PROCESS_BOUND,
        "enabled" to enabled,
        "restoresAfterProcessDeath" to false,
        "resumesOnNextAppLaunch" to true,
    )
}
