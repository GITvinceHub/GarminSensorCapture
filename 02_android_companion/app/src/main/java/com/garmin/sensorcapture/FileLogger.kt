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
 * Appends received GarminPacket data to a JSONL file.
 *
 * Each line is a complete JSON object containing:
 * - received_at: ISO8601 UTC timestamp of Android reception
 * - session_id: Copy of sid for quick indexing
 * - All packet fields (pv, sid, pi, dtr, s, gps, meta, ef)
 *
 * File rotation occurs when the current file exceeds MAX_FILE_SIZE_BYTES (100 MB).
 * Rotated files are renamed with a sequence number suffix.
 */
class FileLogger(private val context: Context) {

    companion object {
        const val MAX_FILE_SIZE_BYTES = 100L * 1024L * 1024L  // 100 MB
        const val SESSIONS_DIR        = "sessions"
        const val FILE_EXTENSION      = ".jsonl"
        const val BUFFER_SIZE         = 16384  // 16 KB write buffer
        private val ISO_FORMATTER     = DateTimeFormatter.ISO_INSTANT
    }

    private val gson = Gson()

    /** Directory where JSONL files are stored */
    private val sessionsDir: File by lazy {
        File(context.filesDir, SESSIONS_DIR).also { it.mkdirs() }
    }

    /** Current active session ID */
    private var currentSessionId: String? = null

    /** Current output file */
    private var currentFile: File? = null

    /** Buffered writer to the current file */
    private var writer: BufferedWriter? = null

    /** Number of packets logged to current file */
    @Volatile
    private var packetsInCurrentFile: Long = 0L

    /** Rotation sequence number */
    private var rotationIndex: Int = 0

    /**
     * Open (or reopen) the JSONL file for the given session.
     * If a different session was previously open, closes it first.
     *
     * @param sessionId The session identifier
     */
    @Synchronized
    fun openSession(sessionId: String) {
        if (currentSessionId == sessionId && writer != null) {
            return  // Already open
        }

        // Close previous session if open
        closeCurrentFile()

        currentSessionId  = sessionId
        rotationIndex     = 0
        packetsInCurrentFile = 0L

        openFile(sessionId, rotationIndex)
        Log.d(TAG, "Opened session file: ${currentFile?.name}")
    }

    /**
     * Append a packet as a JSONL line to the current file.
     * Triggers rotation if file exceeds MAX_FILE_SIZE_BYTES.
     *
     * @param packet The received GarminPacket
     * @throws IllegalStateException if no session is open
     */
    @Synchronized
    fun logPacket(packet: GarminPacket) {
        val sessionId = currentSessionId
            ?: throw IllegalStateException("No session open. Call openSession() first.")

        // Auto-open if writer was closed
        if (writer == null) {
            openFile(sessionId, rotationIndex)
        }

        // Check rotation
        if (shouldRotate()) {
            rotateFile()
        }

        // Build the enriched JSONL line
        val receivedAt = ISO_FORMATTER.format(Instant.now())
        val lineObj = buildJsonlObject(packet, receivedAt, sessionId)
        val jsonLine = gson.toJson(lineObj)

        try {
            writer?.write(jsonLine)
            writer?.newLine()
            // Flush every 10 packets to balance I/O and data safety
            packetsInCurrentFile++
            if (packetsInCurrentFile % 10 == 0L) {
                writer?.flush()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Write error: ${e.message}")
            throw e
        }
    }

    /**
     * Build the object that gets serialized to a JSONL line.
     * Adds received_at and session_id at the top level.
     */
    private fun buildJsonlObject(
        packet: GarminPacket,
        receivedAt: String,
        sessionId: String
    ): Map<String, Any?> {
        return mapOf(
            "received_at" to receivedAt,
            "session_id"  to sessionId,
            "pv"          to packet.protocolVersion,
            "pt"          to packet.packetType,       // "header" | "footer" | null
            "sid"         to packet.sessionId,
            "pi"          to packet.packetIndex,
            "dtr"         to packet.deviceTimeReference,
            "s"           to packet.samplesOrEmpty,   // never null in JSONL output
            "gps"         to packet.gps,
            "meta"        to packet.meta,
            "ef"          to packet.errorFlags
        )
    }

    /**
     * Flush and close the current writer, without clearing session info.
     */
    @Synchronized
    fun flush() {
        try {
            writer?.flush()
        } catch (e: Exception) {
            Log.e(TAG, "Flush error: ${e.message}")
        }
    }

    /**
     * Flush, close writer, and clear session state.
     * Call this when the session ends.
     */
    @Synchronized
    fun flushAndClose() {
        closeCurrentFile()
        currentSessionId = null
        Log.d(TAG, "Session file closed")
    }

    /**
     * Get the current JSONL file path.
     * @return Absolute path string, or null if no file is open
     */
    fun getCurrentFilePath(): String? = currentFile?.absolutePath

    /**
     * Get the current file size in bytes.
     * @return Size in bytes, or 0 if no file
     */
    fun getCurrentFileSize(): Long = currentFile?.length() ?: 0L

    /**
     * Get the total packets logged to the current file.
     */
    fun getPacketsLogged(): Long = packetsInCurrentFile

    /**
     * List all JSONL files for a given session.
     * @param sessionId The session ID prefix
     * @return List of File objects, sorted by name
     */
    fun getSessionFiles(sessionId: String): List<File> {
        return sessionsDir.listFiles { f ->
            f.name.startsWith(sessionId) && f.name.endsWith(FILE_EXTENSION)
        }?.sortedBy { it.name } ?: emptyList()
    }

    /**
     * List all JSONL files in the sessions directory.
     */
    fun getAllSessionFiles(): List<File> {
        return sessionsDir.listFiles { f -> f.name.endsWith(FILE_EXTENSION) }
            ?.sortedByDescending { it.lastModified() } ?: emptyList()
    }

    // ── Private helpers ──────────────────────────────────────────────

    private fun openFile(sessionId: String, index: Int) {
        val suffix = if (index == 0) "" else "_$index"
        val fileName = "$sessionId$suffix$FILE_EXTENSION"
        currentFile = File(sessionsDir, fileName)

        try {
            writer = BufferedWriter(FileWriter(currentFile!!, true), BUFFER_SIZE)
        } catch (e: Exception) {
            Log.e(TAG, "Cannot open file ${currentFile?.name}: ${e.message}")
            throw e
        }
    }

    private fun shouldRotate(): Boolean {
        return (currentFile?.length() ?: 0L) >= MAX_FILE_SIZE_BYTES
    }

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
        } catch (e: Exception) {
            Log.e(TAG, "Close error: ${e.message}")
        } finally {
            writer = null
        }
    }
}
