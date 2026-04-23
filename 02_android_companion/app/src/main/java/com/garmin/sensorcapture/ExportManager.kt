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
 * Handles exporting and sharing JSONL session files.
 *
 * Provides:
 * - exportJsonl: copy JSONL to the shared Downloads directory
 * - exportZip: create a ZIP archive containing the JSONL file
 * - shareFile: launch Android share sheet for a given URI
 */
class ExportManager(private val context: Context) {

    companion object {
        private const val EXPORT_DIR = "exports"
        private const val AUTHORITY_SUFFIX = ".provider"
        private const val BUFFER_SIZE = 8192
    }

    private val exportDir: File by lazy {
        File(context.filesDir, EXPORT_DIR).also { it.mkdirs() }
    }

    /**
     * Copy a session's JSONL file to the export directory and return its URI.
     *
     * @param sessionId The session ID (used to find the JSONL file)
     * @param fileLogger FileLogger instance to get the current file path
     * @return Content URI of the exported file, or null on failure
     */
    fun exportJsonl(sessionId: String, fileLogger: FileLogger): Uri? {
        val sourceFiles = fileLogger.getSessionFiles(sessionId)
        if (sourceFiles.isEmpty()) {
            Log.w(TAG, "No JSONL files found for session $sessionId")
            return null
        }

        // If multiple files (rotated), use the first one; for full export use ZIP
        val sourceFile = sourceFiles.first()
        val destFile = File(exportDir, sourceFile.name)

        return try {
            copyFile(sourceFile, destFile)
            getUriForFile(destFile)
        } catch (e: Exception) {
            Log.e(TAG, "exportJsonl failed: ${e.message}")
            null
        }
    }

    /**
     * Create a ZIP archive containing all JSONL files for a session.
     *
     * @param sessionId  The session ID
     * @param fileLogger FileLogger instance to enumerate session files
     * @return Content URI of the ZIP file, or null on failure
     */
    fun exportZip(sessionId: String, fileLogger: FileLogger): Uri? {
        val sourceFiles = fileLogger.getSessionFiles(sessionId)
        if (sourceFiles.isEmpty()) {
            Log.w(TAG, "No files found for session $sessionId")
            return null
        }

        val zipFile = File(exportDir, "${sessionId}.zip")

        return try {
            ZipOutputStream(FileOutputStream(zipFile)).use { zos ->
                for (file in sourceFiles) {
                    FileInputStream(file).use { fis ->
                        val entry = ZipEntry(file.name)
                        zos.putNextEntry(entry)
                        val buffer = ByteArray(BUFFER_SIZE)
                        var len: Int
                        while (fis.read(buffer).also { len = it } > 0) {
                            zos.write(buffer, 0, len)
                        }
                        zos.closeEntry()
                    }
                    Log.d(TAG, "Zipped: ${file.name} (${file.length()} bytes)")
                }
            }
            Log.i(TAG, "ZIP created: ${zipFile.name} (${zipFile.length()} bytes)")
            getUriForFile(zipFile)
        } catch (e: Exception) {
            Log.e(TAG, "exportZip failed: ${e.message}")
            null
        }
    }

    /**
     * Launch Android share sheet for a file URI.
     *
     * @param fileUri  Content URI of the file to share
     * @param mimeType MIME type (e.g., "application/json", "application/zip")
     */
    fun shareFile(fileUri: Uri, mimeType: String = "application/octet-stream") {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = mimeType
            putExtra(Intent.EXTRA_STREAM, fileUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val chooser = Intent.createChooser(intent, "Share Session Data")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        context.startActivity(chooser)
    }

    /**
     * Delete a session's export files (cleanup).
     *
     * @param sessionId The session ID prefix
     * @return Number of files deleted
     */
    fun deleteExports(sessionId: String): Int {
        val files = exportDir.listFiles { f -> f.name.startsWith(sessionId) } ?: return 0
        return files.count { it.delete() }
    }

    /**
     * Get a FileProvider URI for a file in the exports directory.
     */
    private fun getUriForFile(file: File): Uri {
        return FileProvider.getUriForFile(
            context,
            "${context.packageName}$AUTHORITY_SUFFIX",
            file
        )
    }

    /**
     * Copy a file using buffered I/O.
     */
    private fun copyFile(source: File, dest: File) {
        FileInputStream(source).use { fis ->
            FileOutputStream(dest).use { fos ->
                val buffer = ByteArray(BUFFER_SIZE)
                var len: Int
                while (fis.read(buffer).also { len = it } > 0) {
                    fos.write(buffer, 0, len)
                }
            }
        }
    }

    /**
     * List all files in the export directory.
     * @return List of File objects
     */
    fun listExports(): List<File> {
        return exportDir.listFiles()?.sortedByDescending { it.lastModified() } ?: emptyList()
    }

    /**
     * Get total size of all exports in bytes.
     */
    fun getTotalExportSize(): Long {
        return exportDir.listFiles()?.sumOf { it.length() } ?: 0L
    }
}
