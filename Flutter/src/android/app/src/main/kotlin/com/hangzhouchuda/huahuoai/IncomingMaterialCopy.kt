package com.hangzhouchuda.huahuoai

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream

internal class IncomingMaterialCopyException(
    val code: String,
) : IOException(code)

/**
 * Streams an external provider into app-private storage without first allowing
 * an unbounded file to consume the device cache.
 */
internal fun copyIncomingMaterialBounded(
    input: InputStream,
    destination: File,
    maximumBytes: Long,
): Long {
    if (maximumBytes <= 0) {
        throw IncomingMaterialCopyException("INCOMING_MATERIAL_TOO_LARGE")
    }
    var copiedBytes = 0L
    try {
        input.use { readable ->
            FileOutputStream(destination).use { output ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val count = readable.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    val nextSize = copiedBytes + count
                    if (nextSize > maximumBytes) {
                        throw IncomingMaterialCopyException("INCOMING_MATERIAL_TOO_LARGE")
                    }
                    output.write(buffer, 0, count)
                    copiedBytes = nextSize
                }
            }
        }
        if (copiedBytes == 0L) {
            throw IncomingMaterialCopyException("INCOMING_MATERIAL_EMPTY")
        }
        return copiedBytes
    } catch (error: Throwable) {
        runCatching { destination.delete() }
        throw error
    }
}
