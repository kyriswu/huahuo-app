package com.hangzhouchuda.huahuoai

internal class RecordingCardFileDirectory(
    initialFiles: List<Map<String, Any>> = emptyList(),
) {
    @Volatile
    private var committedFiles = immutableRows(initialFiles)

    fun snapshot(): List<Map<String, Any>> = committedFiles

    fun beginScan(): PendingRows = PendingRows()

    fun commit(rows: PendingRows): List<Map<String, Any>> {
        val nextFiles = rows.snapshot()
        committedFiles = nextFiles
        return nextFiles
    }

    fun remove(deviceFileId: String) {
        committedFiles = committedFiles.filterNot { row ->
            row["deviceFileId"] == deviceFileId
        }
    }

    internal class PendingRows {
        private val rows = mutableListOf<Map<String, Any>>()

        val size: Int
            get() = rows.size

        fun add(row: Map<String, Any>) {
            rows += row.toMap()
        }

        internal fun snapshot(): List<Map<String, Any>> = immutableRows(rows)
    }

    private companion object {
        fun immutableRows(rows: List<Map<String, Any>>): List<Map<String, Any>> =
            rows.map(Map<String, Any>::toMap)
    }
}
