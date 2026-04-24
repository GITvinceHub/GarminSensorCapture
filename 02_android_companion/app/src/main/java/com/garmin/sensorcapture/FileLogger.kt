package com.garmin.sensorcapture

import android.content.Context
import android.util.Log
import com.garmin.sensorcapture.models.GarminPacket
import com.google.gson.Gson
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Append-only JSONL writer for one session at a time (SPEC §4.4).
 *
 *  - FR-040: one JSONL file per session
 *  - FR-041: rotate when current file > 100 MB (next packet goes to .2.jsonl, etc.)
 *  - FR-042: flush every 10 packets
 *  - NFR-021: files live in context.filesDir/sessions/ (app sandbox)
 *  - §8.5: each row carries received_at (ISO-8601 UTC) + session_id + full packet
 */
class FileLogger(private val context: Context) {

    companion object {
        private const val TAG = "FileLogger"
        const val MAX_FILE_BYTES: Long = 100L * 1024L * 1024L // 100 MB — FR-041
        const val FLUSH_EVERY_N: Int = 10                     // FR-042
    }

    private val gson = Gson()
    private val isoFormatter: SimpleDateFormat = SimpleDateFormat(
        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US
    ).apply { timeZone = TimeZone.getTimeZone("UTC") }

    private var sessionId: String? = null
    private var sessionDir: File? = null
    private var currentFile: File? = null
    private var writer: BufferedWriter? = null
    private var currentRotation: Int = 1
    private var packetsSinceFlush: Int = 0
    private var totalBytesWritten: Long = 0L

    @Synchronized
    fun openSession(sid: String) {
        try {
            flushAndCloseInternal()

            val baseDir = File(context.filesDir, "sessions").apply { mkdirs() }
            sessionDir = baseDir
            sessionId = sid
            currentRotation = 1
            packetsSinceFlush = 0
            totalBytesWritten = 0L

            val file = File(baseDir, "$sid.jsonl")
            currentFile = file
            writer = BufferedWriter(FileWriter(file, /*append=*/ true))
            if (file.exists()) totalBytesWritten = file.length()
        } catch (t: Throwable) {
            Log.e(TAG, "openSession failed", t)
            writer = null
        }
    }

    @Synchronized
    fun logPacket(packet: GarminPacket) {
        if (writer == null) {
            Log.w(TAG, "logPacket called with no open session")
            return
        }
        val sid = sessionId ?: return

        try {
            // Rotation check (FR-041)
            if (totalBytesWritten >= MAX_FILE_BYTES) {
                rotate()
            }

            val row = buildRow(packet, sid)
            val line = gson.toJson(row)
            val currentWriter = writer ?: return
            currentWriter.write(line)
            currentWriter.newLine()
            totalBytesWritten += line.length.toLong() + 1L // newline

            packetsSinceFlush++
            if (packetsSinceFlush >= FLUSH_EVERY_N) {
                currentWriter.flush()
                packetsSinceFlush = 0
            }
        } catch (t: Throwable) {
            Log.e(TAG, "logPacket failed", t)
        }
    }

    private fun buildRow(packet: GarminPacket, sid: String): Map<String, Any?> {
        val receivedAt = isoFormatter.format(Date())
        return mapOf(
            "received_at" to receivedAt,
            "session_id" to sid,
            "pv" to packet.protocolVersion,
            "pt" to packet.packetType,
            "sid" to packet.sessionId,
            "pi" to packet.packetIndex,
            "dtr" to packet.deviceTimeReference,
            "s" to packet.samplesOrEmpty, // NEVER null (critical — SC-002)
            "rr" to packet.rrIntervals,
            "gps" to packet.gps,
            "meta" to packet.meta,
            "ef" to packet.errorFlags,
            "user" to packet.user,
            "device" to packet.device,
            "history" to packet.history
        )
    }

    private fun rotate() {
        try {
            writer?.flush()
            writer?.close()
        } catch (t: Throwable) {
            Log.e(TAG, "rotate close failed", t)
        }
        val sid = sessionId ?: return
        val dir = sessionDir ?: return
        currentRotation++
        val newFile = File(dir, "$sid.$currentRotation.jsonl")
        currentFile = newFile
        writer = try {
            BufferedWriter(FileWriter(newFile, true))
        } catch (t: Throwable) {
            Log.e(TAG, "rotate open failed", t)
            null
        }
        totalBytesWritten = 0L
        packetsSinceFlush = 0
    }

    @Synchronized
    fun flush() {
        try {
            writer?.flush()
            packetsSinceFlush = 0
        } catch (t: Throwable) {
            Log.e(TAG, "flush failed", t)
        }
    }

    @Synchronized
    fun flushAndClose() {
        flushAndCloseInternal()
    }

    private fun flushAndCloseInternal() {
        try {
            writer?.flush()
            writer?.close()
        } catch (t: Throwable) {
            Log.e(TAG, "flushAndClose failed", t)
        } finally {
            writer = null
            // keep sessionId / currentFile so the caller can still inspect file size
        }
    }

    @Synchronized
    fun getCurrentFileSize(): Long {
        return try {
            currentFile?.length() ?: 0L
        } catch (t: Throwable) {
            0L
        }
    }

    fun getSessionFile(sid: String): File? {
        val dir = File(context.filesDir, "sessions")
        val primary = File(dir, "$sid.jsonl")
        return if (primary.exists()) primary else null
    }

    fun getSessionFiles(sid: String): List<File> {
        val dir = File(context.filesDir, "sessions")
        if (!dir.exists()) return emptyList()
        return try {
            dir.listFiles { f ->
                f.name == "$sid.jsonl" || f.name.startsWith("$sid.") && f.name.endsWith(".jsonl")
            }?.toList()?.sortedBy { it.name } ?: emptyList()
        } catch (t: Throwable) {
            emptyList()
        }
    }
}
