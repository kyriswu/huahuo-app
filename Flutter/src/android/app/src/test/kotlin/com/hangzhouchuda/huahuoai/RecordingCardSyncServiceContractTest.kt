package com.hangzhouchuda.huahuoai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RecordingCardSyncServiceContractTest {
    @Test
    fun onlyExplicitStartActionCanRunService() {
        assertTrue(
            RecordingCardSyncServiceContract.acceptsAction(
                RecordingCardSyncServiceContract.ACTION_START,
            ),
        )
        assertFalse(
            RecordingCardSyncServiceContract.acceptsAction(
                RecordingCardSyncServiceContract.ACTION_STOP,
            ),
        )
        assertFalse(RecordingCardSyncServiceContract.acceptsAction(null))
        assertFalse(RecordingCardSyncServiceContract.acceptsAction("unexpected"))
    }

    @Test
    fun capabilityNeverClaimsHeadlessProcessDeathRecovery() {
        val enabled = RecordingCardSyncServiceContract.capability(true)

        assertEquals(
            RecordingCardSyncServiceContract.MODE_PROCESS_BOUND,
            enabled["mode"],
        )
        assertEquals(true, enabled["enabled"])
        assertEquals(false, enabled["restoresAfterProcessDeath"])
        assertEquals(true, enabled["resumesOnNextAppLaunch"])

        val disabled = RecordingCardSyncServiceContract.capability(false)
        assertEquals(false, disabled["enabled"])
        assertEquals(false, disabled["restoresAfterProcessDeath"])
        assertEquals(true, disabled["resumesOnNextAppLaunch"])
    }

    @Test
    fun serviceAndWakeLockFollowIndependentOwnershipFacts() {
        val idle = state()
        assertFalse(RecordingCardSyncServiceContract.shouldRun(idle))
        assertFalse(RecordingCardSyncServiceContract.shouldHoldWakeLock(idle))

        val monitoring = state(dartKeepAlive = true)
        assertTrue(RecordingCardSyncServiceContract.shouldRun(monitoring))
        assertFalse(RecordingCardSyncServiceContract.shouldHoldWakeLock(monitoring))

        val dartBleTransfer = state(
            dartTransferActive = true,
            dartTransferTransport = RecordingCardSyncTransport.BLUETOOTH,
        )
        assertTrue(RecordingCardSyncServiceContract.shouldRun(dartBleTransfer))
        assertTrue(RecordingCardSyncServiceContract.shouldHoldWakeLock(dartBleTransfer))

        val nativeWifiTransfer = state(nativeWifiTransferActive = true)
        assertTrue(RecordingCardSyncServiceContract.shouldRun(nativeWifiTransfer))
        assertTrue(RecordingCardSyncServiceContract.shouldHoldWakeLock(nativeWifiTransfer))
    }

    @Test
    fun notificationCopyFollowsTransferTransportWithoutDeviceLightClaims() {
        assertEquals("录音卡后台连接", RecordingCardSyncServiceContract.CHANNEL_NAME)
        assertEquals(
            "保持录音卡状态监听与文件同步连接",
            RecordingCardSyncServiceContract.CHANNEL_DESCRIPTION,
        )
        assertEquals(
            "录音卡后台连接",
            RecordingCardSyncServiceContract.notificationTitle(state(dartKeepAlive = true)),
        )
        assertEquals(
            "正在监听录音卡连接与录音状态",
            RecordingCardSyncServiceContract.notificationText(state(dartKeepAlive = true)),
        )
        val ble = state(
            dartKeepAlive = true,
            dartTransferActive = true,
            dartTransferTransport = RecordingCardSyncTransport.BLUETOOTH,
        )
        assertEquals("正在通过蓝牙同步录音", RecordingCardSyncServiceContract.notificationTitle(ble))
        assertEquals("蓝牙文件传输将在后台继续", RecordingCardSyncServiceContract.notificationText(ble))

        val wifi = state(nativeWifiTransferActive = true)
        assertEquals("正在通过 WiFi 同步录音", RecordingCardSyncServiceContract.notificationTitle(wifi))
        assertEquals("WiFi 文件传输将在后台继续", RecordingCardSyncServiceContract.notificationText(wifi))

        val allCopy = listOf(
            RecordingCardSyncServiceContract.notificationTitle(state(dartKeepAlive = true)),
            RecordingCardSyncServiceContract.notificationText(state(dartKeepAlive = true)),
            RecordingCardSyncServiceContract.notificationTitle(ble),
            RecordingCardSyncServiceContract.notificationText(ble),
            RecordingCardSyncServiceContract.notificationTitle(wifi),
            RecordingCardSyncServiceContract.notificationText(wifi),
        ).joinToString(" ")
        assertFalse(allCopy.contains("灯"))
        assertFalse(allCopy.contains("自动同步"))
    }

    private fun state(
        dartKeepAlive: Boolean = false,
        dartTransferActive: Boolean = false,
        dartTransferTransport: RecordingCardSyncTransport? = null,
        nativeWifiTransferActive: Boolean = false,
    ): RecordingCardSyncServiceState = RecordingCardSyncServiceState(
        dartKeepAlive = dartKeepAlive,
        dartTransferActive = dartTransferActive,
        dartTransferTransport = dartTransferTransport,
        nativeWifiTransferActive = nativeWifiTransferActive,
    )
}
