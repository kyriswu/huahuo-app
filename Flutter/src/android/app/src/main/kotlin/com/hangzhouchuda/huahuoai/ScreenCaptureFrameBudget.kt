package com.hangzhouchuda.huahuoai

internal enum class ScreenCaptureThermalLevel { normal, warm, severe, critical }

internal data class ScreenCapturePowerState(
    val thermalLevel: ScreenCaptureThermalLevel,
    val lowPower: Boolean,
)

internal class ScreenCaptureFrameBudget(
    private val maximumFrameRate: Int,
    private val recoveryDelayNanos: Long = 30_000_000_000L,
) {
    init {
        require(maximumFrameRate in 1..15)
        require(recoveryDelayNanos >= 0L)
    }

    var frameRate: Int = maximumFrameRate
        private set
    private var recoveryRate: Int? = null
    private var recoveryStartedAt = 0L
    private var lastFrameAt: Long? = null

    fun update(state: ScreenCapturePowerState, nowNanos: Long) {
        val target = minOf(maximumFrameRate, frameRateFor(state))
        if (target <= frameRate) {
            frameRate = target
            recoveryRate = null
            return
        }
        if (recoveryRate != target) {
            recoveryRate = target
            recoveryStartedAt = nowNanos
        }
        if (nowNanos - recoveryStartedAt >= recoveryDelayNanos) {
            frameRate = target
            recoveryRate = null
        }
    }

    fun shouldRender(nowNanos: Long): Boolean {
        val previous = lastFrameAt
        if (previous != null && nowNanos - previous < 1_000_000_000L / frameRate) {
            return false
        }
        lastFrameAt = nowNanos
        return true
    }

    companion object {
        fun frameRateFor(state: ScreenCapturePowerState): Int = when (state.thermalLevel) {
            ScreenCaptureThermalLevel.critical -> 2
            ScreenCaptureThermalLevel.severe -> 5
            ScreenCaptureThermalLevel.warm -> 10
            ScreenCaptureThermalLevel.normal -> if (state.lowPower) 10 else 15
        }
    }
}
