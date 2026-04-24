package com.garmin.sensorcapture

import android.content.Context
import android.util.Log
import com.garmin.sensorcapture.models.GarminPacket
import com.google.gson.Gson
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.time.Instant
import java.time.format.DateTimeFormatter

private const val TAG = "FileLogger"

/**
 * Appends received [GarminPacket]s to a JSONL file under [Context.filesDir].
 *
 * Implements contracts supporting FR-040..FR-042 per SPECIFICATION.md §4.4.
 * File format follows SPECIFICATION.md §8.5.
 *
 *  - FR-040: one JSONL line per packet (header, data, footer all written)
 *  - FR-041: rotate file when it exceeds [MAX_FILE_SIZE_BYTES] (100 MB)
 *  - FR-042: flush buffered writer every [FLUSH_EVERY_N] (10) packets
 *  - NFR-021: all files live inside the app sandbox
 */
class FileLogger(private val context: Context) {

    companion object {
        /** FR-041: file rotation threshold (100 MB). */
        const val MAX_FILE_SIZE_BYTES = 100L * 1024L * 1024L
        /** FR-042: flush cadence (packets). */
        const val FLUSH_EVERY_N       = 10L
        const val SESSIONS_DIR        = "sessions"
        const val FILE_EXTENSION      = ".jsonl"
        /** 16 KB buffered writer — amortises I/O on BLE burst arrivals. */
        const val BUFFER_SIZE         = 16384
        private val ISO_FORMATTER     = DateTimeFormatter.ISO_INSTANT
    }

    private val gson = Gson()

    private val sessionsDir: File by lazy {
        File(context.filesDir, SESSIONS_DIR).also { it.mkdirs() }
    }

    private var currentSessionId: String? = null
    private var currentFile: File? = null
    private var writer: BufferedWriter? = null

    @Volatile
    private var packetsInCurrentFile: Long = 0L

    private var rotationIndex: Int = 0

    /**
     * Open (or reopen) the JSONL file for the given session.
     * Closes any previously open file first.
     */
    @Synchronized
    fun openSession(sessionId: String) {
        if (currentSessionId == sessionId && writer != null) return

        closeCurrentFile()
        currentSessionId     = sessionId
        rotationIndex        = 0
        packetsInCurrentFile = 0L

        openFile(sessionId, rotationIndex)
        Log.i(TAG, "Opened session file: ${currentFile?.name}")
    }

    /**
     * Append a packet as a JSONL line.
     * Triggers rotation (FR-041) and flush (FR-042) as needed.
     *
     * Throws IllegalStateException if no session is open. Callers in the
     * hot path (GarminReceiver) wrap this call in a try/catch.
     */
    @Synchronized
    fun logPacket(packet: GarminPacket) {
        val sessionId = currentSessionId
            ?: throw IllegalStateException("No session open; call openSession() first")

        if (writer == null) {
            openFile(sessionId, rotationIndex)
        }

        if (shouldRotate()) {
            rotateFile()
        }

        val receivedAt = ISO_FORMATTER.format(Instant.now())
        val line = gson.toJson(buildJsonlObject(packet, receivedAt, sessionId))

        writer?.write(line)
        writer?.newLine()

        packetsInCurrentFile++
        if (packetsInCurrentFile % FLUSH_EVERY_N == 0L) {
            writer?.flush()  // FR-042
        }
    }

    /**
     * Build the JSONL record (SPECIFICATION.md §8.5).
     *
     * Uses [GarminPacket.samplesOrEmpty] (never null) so that header/footer
     * packets are serialised with `"s":[]` rather than `"s":null` — makes
     * downstream Python consumers simpler. Always emits `"pt"` so meta
     * packets are discoverable.
     */
    private fun buildJsonlObject(
        packet: GarminPacket,
        receivedAt: String,
        sessionId: String
    ): Map<String, Any?> = linkedMapOf(
        "received_at" to receivedAt,
        "session_id"  to sessionId,
        "pv"          to packet.protocolVersion,
        "pt"          to packet.packetType,           // "header" | "footer" | null
        "sid"         to packet.sessionId,
        "pi"          to packet.packetIndex,
        "dtr"         to packet.deviceTimeReference,
        "s"           to packet.samplesOrEmpty,       // always non-null (C-061)
        "rr"          to packet.rrIntervals,
        "gps"         to packet.gps,
        "meta"        to packet.meta,
        "ef"          to packet.errorFlags,
        "user"        to packet.user,
        "device"      to packet.device,
        "history"     to packet.history
    )

    @Synchronized
    fun flush() {
        try { writer?.flush() }
        catch (t: Throwable) { Log.e(TAG, "flush: ${t.message}") }
    }

    @Synchronized
    fun flushAndClose() {
        closeCurrentFile()
        currentSessionId = null
        Log.i(TAG, "Session file closed")
    }

    fun getCurrentFilePath(): String? = currentFile?.absolutePath
    fun getCurrentFileSize(): Long    = currentFile?.length() ?: 0L
    fun getPacketsLogged(): Long      = packetsInCurrentFile

    /** All JSONL files belonging to [sessionId] (includes rotated parts). */
    fun getSessionFiles(sessionId: String): List<File> =
        sessionsDir.listFiles { f ->
            f.name.startsWith(sessionId) && f.name.endsWith(FILE_EXTENSION)
        }?.sortedBy { it.name } ?: emptyList()

    /** All JSONL files on disk, newest first. */
    fun getAllSessionFiles(): List<File> =
        sessionsDir.listFiles { f -> f.name.endsWith(FILE_EXTENSION) }
            ?.sortedByDescending { it.lastModified() } ?: emptyList()

    // ── Private ──────────────────────────────────────────────────────

    private fun openFile(sessionId: String, index: Int) {
        val suffix = if (index == 0) "" else "_$index"
        val fileName = "$sessionId$suffix$FILE_EXTENSION"
        currentFile = File(sessionsDir, fileName)
        writer = BufferedWriter(FileWriter(currentFile!!, true), BUFFER_SIZE)
    }

    private fun shouldRotate(): Boolean =
        (currentFile?.length() ?: 0L) >= MAX_FILE_SIZE_BYTES

    private fun rotateFile() {
        closeCurrentFile()
        rotationIndex++
        packetsInCurrentFile = 0L
        openFile(currentSessionId!!, rotationIndex)
        Log.i(TAG, "Rotated to file index $rotationIndex: ${currentFile?.name}")
    }

    private fun closeCurrentFile() {
        try {
            writer?.flush()
            writer?.close()
        } catch (t: Throwable) {
            Log.e(TAG, "close: ${t.message}")
        } finally {
            writer = null
        }
    }
}
