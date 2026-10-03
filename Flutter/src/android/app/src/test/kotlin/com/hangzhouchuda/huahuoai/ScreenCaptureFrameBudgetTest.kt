package com.hangzhouchuda.huahuoai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenCaptureFrameBudgetTest {
    private fun power(level: ScreenCaptureThermalLevel, lowPower: Boolean = false) =
        ScreenCapturePowerState(level, lowPower)

    @Test
    fun downgradesDuringTheSameRecordingAndCapsEncoderRate() {
        val budget = ScreenCaptureFrameBudget(15)
        budget.update(power(ScreenCaptureThermalLevel.normal), 0L)
        assertEquals(15, budget.frameRate)
        budget.update(power(ScreenCaptureThermalLevel.normal, lowPower = true), 1L)
        assertEquals(10, budget.frameRate)
        budget.update(power(ScreenCaptureThermalLevel.severe), 2L)
        assertEquals(5, budget.frameRate)
        budget.update(power(ScreenCaptureThermalLevel.critical), 3L)
        assertEquals(2, budget.frameRate)
        val constrainedEncoder = ScreenCaptureFrameBudget(5)
        constrainedEncoder.update(power(ScreenCaptureThermalLevel.normal), 0L)
        assertEquals(5, constrainedEncoder.frameRate)
    }

    @Test
    fun recoveryRequiresThirtySecondsAtOneStableTarget() {
        val budget = ScreenCaptureFrameBudget(15)
        budget.update(power(ScreenCaptureThermalLevel.severe), 0L)
        budget.update(power(ScreenCaptureThermalLevel.normal), 1_000_000_000L)
        budget.update(power(ScreenCaptureThermalLevel.normal), 30_999_999_999L)
        assertEquals(5, budget.frameRate)
        budget.update(power(ScreenCaptureThermalLevel.normal), 31_000_000_000L)
        assertEquals(15, budget.frameRate)
    }

    @Test
    fun changingRecoveryTargetRestartsTheRecoveryWindow() {
        val budget = ScreenCaptureFrameBudget(15)
        budget.update(power(ScreenCaptureThermalLevel.critical), 0L)
        budget.update(power(ScreenCaptureThermalLevel.normal), 1_000_000_000L)
        budget.update(power(ScreenCaptureThermalLevel.warm), 20_000_000_000L)
        budget.update(power(ScreenCaptureThermalLevel.warm), 31_000_000_000L)
        assertEquals(2, budget.frameRate)
        budget.update(power(ScreenCaptureThermalLevel.warm), 50_000_000_000L)
        assertEquals(10, budget.frameRate)
        budget.update(power(ScreenCaptureThermalLevel.critical), 50_000_000_001L)
        assertEquals(2, budget.frameRate)
    }

    @Test
    fun returnedHotStateCancelsPendingRecovery() {
        val budget = ScreenCaptureFrameBudget(15)
        budget.update(power(ScreenCaptureThermalLevel.severe), 0L)
        budget.update(power(ScreenCaptureThermalLevel.normal), 1_000_000_000L)
        budget.update(power(ScreenCaptureThermalLevel.severe), 30_000_000_000L)
        budget.update(power(ScreenCaptureThermalLevel.normal), 31_000_000_000L)
        assertEquals(5, budget.frameRate)
        budget.update(power(ScreenCaptureThermalLevel.normal), 61_000_000_000L)
        assertEquals(15, budget.frameRate)
    }

    @Test
    fun forwardingAdoptsTheNewBudgetWithoutCatchup() {
        val budget = ScreenCaptureFrameBudget(15)
        assertTrue(budget.shouldRender(0L))
        assertFalse(budget.shouldRender(60_000_000L))
        assertTrue(budget.shouldRender(70_000_000L))
        budget.update(power(ScreenCaptureThermalLevel.severe), 70_000_001L)
        assertFalse(budget.shouldRender(140_000_000L))
        assertTrue(budget.shouldRender(270_000_000L))
        budget.update(power(ScreenCaptureThermalLevel.critical), 270_000_001L)
        assertFalse(budget.shouldRender(470_000_000L))
        assertTrue(budget.shouldRender(770_000_000L))
        assertTrue(budget.shouldRender(60_000_000_000L))
        assertFalse(budget.shouldRender(60_000_000_001L))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsZeroFrameRate() {
        ScreenCaptureFrameBudget(0)
    }
}
