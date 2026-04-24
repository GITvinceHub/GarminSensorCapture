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

/**
 * Exports session artifacts via FileProvider + ACTION_SEND (NFR-022, FR-043, SC-008).
 *
 * The FileProvider authority matches AndroidManifest.xml:
 *     ${applicationId}.provider
 *
 * Exported artifacts are staged in cacheDir/exports/ so they are easy to clean.
 */
class ExportManager(private val context: Context) {

    companion object {
        private const val TAG = "ExportManager"
        private const val AUTHORITY_SUFFIX = ".provider"
    }

    private val authority: String
        get() = context.applicationContext.packageName + AUTHORITY_SUFFIX

    private fun exportsDir(): File =
        File(context.cacheDir, "exports").apply { mkdirs() }

    /** Copy the JSONL into cacheDir/exports and return a shareable FileProvider Uri. */
    fun exportJsonl(sid: String, logger: FileLogger): Uri? {
        return try {
            logger.flush()
            val source = logger.getSessionFile(sid) ?: return null
            if (!source.exists()) return null

            val dest = File(exportsDir(), "$sid.jsonl")
            source.copyTo(dest, overwrite = true)
            FileProvider.getUriForFile(context, authority, dest)
        } catch (t: Throwable) {
            Log.e(TAG, "exportJsonl failed", t)
            null
        }
    }

    /** Zip all JSONL parts of the session and return a shareable Uri. */
    fun exportZip(sid: String, logger: FileLogger): Uri? {
        return try {
            logger.flush()
            val parts = logger.getSessionFiles(sid)
            if (parts.isEmpty()) return null

            val zipFile = File(exportsDir(), "$sid.zip")
            FileOutputStream(zipFile).use { fos ->
                ZipOutputStream(fos.buffered()).use { zos ->
                    for (part in parts) {
                        FileInputStream(part).use { fis ->
                            zos.putNextEntry(ZipEntry(part.name))
                            fis.copyTo(zos)
                            zos.closeEntry()
                        }
                    }
                }
            }
            FileProvider.getUriForFile(context, authority, zipFile)
        } catch (t: Throwable) {
            Log.e(TAG, "exportZip failed", t)
            null
        }
    }

    /** Fire Intent.ACTION_SEND with the given Uri + mime type. */
    fun shareFile(uri: Uri, mime: String) {
        try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val chooser = Intent.createChooser(intent, "Share session")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(chooser)
        } catch (t: Throwable) {
            Log.e(TAG, "shareFile failed", t)
        }
    }
}
