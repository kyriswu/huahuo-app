package com.hangzhouchuda.huahuoai

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class IncomingMaterialCopyTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun copiesAReadableProviderIntoPrivateStorage() {
        val destination = temporaryFolder.newFile("material.pdf")
        destination.delete()

        val copied = copyIncomingMaterialBounded(
            input = ByteArrayInputStream(byteArrayOf(1, 2, 3, 4)),
            destination = destination,
            maximumBytes = 4,
        )

        assertEquals(4L, copied)
        assertTrue(destination.exists())
        assertTrue(destination.readBytes().contentEquals(byteArrayOf(1, 2, 3, 4)))
    }

    @Test
    fun rejectsAnEmptyProviderAndCleansThePartialDestination() {
        val destination = temporaryFolder.newFile("empty.txt")
        destination.delete()

        val error = runCatching {
            copyIncomingMaterialBounded(
                input = ByteArrayInputStream(byteArrayOf()),
                destination = destination,
                maximumBytes = 4,
            )
        }.exceptionOrNull() as IncomingMaterialCopyException

        assertEquals("INCOMING_MATERIAL_EMPTY", error.code)
        assertFalse(destination.exists())
    }

    @Test
    fun rejectsOverLimitInputBeforeItLeavesAPartialFile() {
        val destination = temporaryFolder.newFile("large.pdf")
        destination.delete()

        val error = runCatching {
            copyIncomingMaterialBounded(
                input = ByteArrayInputStream(byteArrayOf(1, 2, 3, 4, 5)),
                destination = destination,
                maximumBytes = 4,
            )
        }.exceptionOrNull() as IncomingMaterialCopyException

        assertEquals("INCOMING_MATERIAL_TOO_LARGE", error.code)
        assertFalse(destination.exists())
    }
}
