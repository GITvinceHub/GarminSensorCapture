package com.garmin.sensorcapture

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

private const val TAG = "ExportManager"

/**
 * Exports JSONL session files via Android's share sheet.
 *
 * Implements FR-043 per SPECIFICATION.md §4.4 and NFR-022 (§5.3) — every
 * external hand-off goes through [FileProvider], never a public URI.
 * Realises scenario SC-008.
 */
class ExportManager(private val context: Context) {

    companion object {
        private const val EXPORT_DIR       = "exports"
        private const val AUTHORITY_SUFFIX = ".provider"
        private const val BUFFER_SIZE      = 8192
    }

    private val exportDir: File by lazy {
        File(context.filesDir, EXPORT_DIR).also { it.mkdirs() }
    }

    /**
     * Copy the first JSONL part of [sessionId] into the exports dir and
     * return a FileProvider URI. Returns null if no files exist.
     */
    fun exportJsonl(sessionId: String, fileLogger: FileLogger): Uri? {
        val files = fileLogger.getSessionFiles(sessionId)
        if (files.isEmpty()) {
            Log.w(TAG, "No JSONL for session $sessionId")
            return null
        }
        val source = files.first()
        val dest   = File(exportDir, source.name)
        return try {
            copyFile(source, dest)
            getUriForFile(dest)
        } catch (t: Throwable) {
            Log.e(TAG, "exportJsonl failed: ${t.message}", t)
            null
        }
    }

    /**
     * Archive all JSONL parts of [sessionId] into a ZIP and return its URI.
     */
    fun exportZip(sessionId: String, fileLogger: FileLogger): Uri? {
        val files = fileLogger.getSessionFiles(sessionId)
        if (files.isEmpty()) {
            Log.w(TAG, "No files for session $sessionId")
            return null
        }
        val zip = File(exportDir, "$sessionId.zip")
        return try {
            ZipOutputStream(FileOutputStream(zip)).use { zos ->
                for (f in files) {
                    FileInputStream(f).use { fis ->
                        zos.putNextEntry(ZipEntry(f.name))
                        val buf = ByteArray(BUFFER_SIZE)
                        var n: Int
                        while (fis.read(buf).also { n = it } > 0) {
                            zos.write(buf, 0, n)
                        }
                        zos.closeEntry()
                    }
                }
            }
            Log.i(TAG, "ZIP created: ${zip.name} (${zip.length()} B)")
            getUriForFile(zip)
        } catch (t: Throwable) {
            Log.e(TAG, "exportZip failed: ${t.message}", t)
            null
        }
    }

    /**
     * Launch the Android share sheet for [fileUri] (FR-043).
     * NFR-022: caller is responsible for passing a FileProvider URI.
     */
    fun shareFile(fileUri: Uri, mimeType: String = "application/octet-stream") {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, fileUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val chooser = Intent.createChooser(send, "Share Session Data")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(chooser)
    }

    /** Delete previously exported copies for [sessionId]; returns count deleted. */
    fun deleteExports(sessionId: String): Int {
        val files = exportDir.listFiles { f -> f.name.startsWith(sessionId) } ?: return 0
        return files.count { it.delete() }
    }

    fun listExports(): List<File> =
        exportDir.listFiles()?.sortedByDescending { it.lastModified() } ?: emptyList()

    fun getTotalExportSize(): Long =
        exportDir.listFiles()?.sumOf { it.length() } ?: 0L

    // ── Private ──────────────────────────────────────────────────────

    private fun getUriForFile(file: File): Uri =
        FileProvider.getUriForFile(
            context,
            "${context.packageName}$AUTHORITY_SUFFIX",
            file
        )

    private fun copyFile(source: File, dest: File) {
        FileInputStream(source).use { fis ->
            FileOutputStream(dest).use { fos ->
                val buf = ByteArray(BUFFER_SIZE)
                var n: Int
                while (fis.read(buf).also { n = it } > 0) {
                    fos.write(buf, 0, n)
                }
            }
        }
    }
}
