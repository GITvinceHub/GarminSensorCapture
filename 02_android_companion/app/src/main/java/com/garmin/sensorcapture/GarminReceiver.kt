package com.garmin.sensorcapture

import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmin.sensorcapture.models.GarminPacket
import com.google.gson.Gson
import com.google.gson.JsonSyntaxException

private const val TAG = "GarminReceiver"

/**
 * Connect IQ message listener on the Android side.
 *
 * Implements contracts C-060 and C-061 per SPECIFICATION.md §7.7.
 * Fulfils FR-013 (ACK each data packet) and FR-014 (never validate samples for
 * meta packets). Realises scenario SC-002 (header packet safety) and SC-010
 * (exception resilience in callbacks — NFR-012).
 *
 * Flow (C-060):
 *   onMessageReceived
 *     └─ try / catch Throwable  ← NFR-012: survive even OOM / LinkageError
 *         └─ _processMessage
 *             ├─ parse JSON → GarminPacket (nullable samples — SC-002)
 *             ├─ validatePacket (C-061)
 *             ├─ fileLogger.logPacket
 *             ├─ sessionManager.onPacketReceived
 *             ├─ if data packet → onSendAck(packetIndex)     (INV-006)
 *             └─ onPacketReceived(packet) → UI layer
 */
class GarminReceiver(
    private val fileLogger: FileLogger,
    private val sessionManager: SessionManager,
    private val onPacketReceived: (GarminPacket) -> Unit,
    private val onError: (String) -> Unit,
    /** Invoked with the packet index for each DATA packet (never meta packets). */
    private val onSendAck: ((Long) -> Unit)? = null
) : ConnectIQ.IQApplicationEventListener {

    private val gson = Gson()

    @Volatile var validPacketsCount: Long = 0L   ; private set
    @Volatile var invalidPacketsCount: Long = 0L ; private set
    @Volatile var gapsDetected: Int = 0          ; private set

    /** Last seen packet index (for gap detection). -1 == none yet. */
    @Volatile
    private var lastPacketIndex: Long = -1L

    /**
     * Connect IQ SDK entry point.  C-060: no exception may propagate.
     *
     * We catch Throwable (not just Exception) because the Garmin BLE SDK has
     * been observed to throw LinkageError / NoClassDefFoundError in some
     * device/OS combinations, and because an OOM here must not kill the app.
     */
    override fun onMessageReceived(
        device: IQDevice?,
        app: IQApp?,
        messageData: MutableList<Any>?,
        status: ConnectIQ.IQMessageStatus?
    ) {
        try {
            _processMessage(device, app, messageData, status)
        } catch (t: Throwable) {
            // Keep the app alive at any cost (NFR-012).
            Log.e(TAG, "FATAL in onMessageReceived: ${t.message}", t)
            invalidPacketsCount++
            try { onError("Internal error: ${t.message?.take(120) ?: t.javaClass.simpleName}") }
            catch (_: Throwable) { /* swallow — best effort */ }
        }
    }

    private fun _processMessage(
        @Suppress("UNUSED_PARAMETER") device: IQDevice?,
        @Suppress("UNUSED_PARAMETER") app: IQApp?,
        messageData: MutableList<Any>?,
        status: ConnectIQ.IQMessageStatus?
    ) {
        if (status != ConnectIQ.IQMessageStatus.SUCCESS) {
            val msg = "Non-SUCCESS message status: ${status?.name}"
            Log.w(TAG, msg)
            onError(msg)
            return
        }

        if (messageData == null) {
            Log.w(TAG, "null messageData")
            invalidPacketsCount++
            return
        }

        val jsonString = extractJsonString(messageData) ?: run {
            Log.e(TAG, "Cannot extract JSON: type=${messageData.javaClass.name}")
            invalidPacketsCount++
            onError("Unparseable CIQ payload: ${messageData.javaClass.simpleName}")
            return
        }

        val packet = parsePacket(jsonString) ?: run {
            invalidPacketsCount++
            return
        }

        if (!validatePacket(packet)) {
            Log.w(TAG, "Packet validation failed for pi=${packet.packetIndex}, pt=${packet.packetType}")
            invalidPacketsCount++
            return
        }

        // Gap detection only for data packets — meta packets may share pi=0 (INV-003).
        if (!packet.isMetaPacket) {
            detectGaps(packet.packetIndex)
        }

        // Persist to disk (FR-040).
        try {
            fileLogger.logPacket(packet)
        } catch (t: Throwable) {
            Log.e(TAG, "FileLogger error: ${t.message}", t)
            onError("File write error: ${t.message?.take(100)}")
        }

        sessionManager.onPacketReceived()
        validPacketsCount++

        if (!packet.isMetaPacket) {
            lastPacketIndex = packet.packetIndex
            // INV-006: ACK is ONLY sent for data packets.
            try { onSendAck?.invoke(packet.packetIndex) }
            catch (t: Throwable) { Log.e(TAG, "onSendAck callback threw: ${t.message}") }
        }

        try { onPacketReceived(packet) }
        catch (t: Throwable) { Log.e(TAG, "onPacketReceived callback threw: ${t.message}") }

        val sampleCount = packet.samples?.size ?: 0
        val label = if (packet.isMetaPacket) "[${packet.packetType}]" else "data"
        Log.v(TAG, "Packet #${packet.packetIndex} $label ($sampleCount samples)")
    }

    /** Unwrap the CIQ message payload to a JSON string. */
    private fun extractJsonString(messageData: Any?): String? = when (messageData) {
        is String   -> messageData
        is List<*>  -> when (val first = messageData.firstOrNull()) {
            is String -> first
            null      -> null
            else      -> first.toString()
        }
        null        -> null
        else        -> messageData.toString()
    }

    /** Parse JSON into a [GarminPacket]. Returns null on failure (never throws). */
    private fun parsePacket(json: String): GarminPacket? = try {
        gson.fromJson(json, GarminPacket::class.java)
    } catch (e: JsonSyntaxException) {
        Log.e(TAG, "JSON parse error: ${e.message} | head=${json.take(200)}")
        onError("JSON parse error: ${e.message?.take(100)}")
        null
    } catch (t: Throwable) {
        Log.e(TAG, "Unexpected parse error: ${t.message}")
        null
    }

    /**
     * Contract C-061 — validatePacket.
     *
     * Returns true iff:
     *   - sessionId is non-null and non-blank
     *   - packetIndex ≥ 0
     *   - protocolVersion is accepted (best-effort: log if unknown, continue)
     *   - For META packets: samples MAY be null (FR-014).
     *   - For DATA packets: samples must be present AND non-empty, UNLESS
     *     isPartial == true (explicitly acknowledged truncated packet).
     */
    internal fun validatePacket(packet: GarminPacket): Boolean {
        if (packet.protocolVersion != GarminPacket.PROTOCOL_VERSION_CURRENT) {
            Log.w(TAG, "Unknown protocol version ${packet.protocolVersion} — continuing best-effort")
        }

        if (packet.sessionId.isNullOrBlank()) {
            Log.w(TAG, "Packet has null/blank sessionId")
            return false
        }

        if (packet.packetIndex < 0) {
            Log.w(TAG, "Negative packetIndex ${packet.packetIndex}")
            return false
        }

        // SC-002 / FR-014: meta packets legitimately carry no samples.
        if (packet.isMetaPacket) {
            return true
        }

        // Data packets MUST carry samples unless PARTIAL flag is set.
        if (packet.samples == null) {
            if (packet.isPartial) return true
            Log.w(TAG, "Data packet ${packet.packetIndex} has no samples and no PARTIAL flag")
            return false
        }

        return true
    }

    private fun detectGaps(currentIndex: Long) {
        if (lastPacketIndex >= 0 && currentIndex > lastPacketIndex + 1) {
            val gap = (currentIndex - lastPacketIndex - 1).toInt()
            gapsDetected += gap
            Log.w(TAG, "Gap: expected pi=${lastPacketIndex + 1} got pi=$currentIndex (gap=$gap)")
            onError("Packet gap: $gap packets lost before pi=$currentIndex")
        }
    }

    /** Reset counters for a new session. */
    fun reset() {
        validPacketsCount   = 0L
        invalidPacketsCount = 0L
        gapsDetected        = 0
        lastPacketIndex     = -1L
    }

    /** Packet loss as a percentage (0..100); 0 if no data. */
    fun getPacketLossPercent(): Float {
        val total = validPacketsCount + gapsDetected
        if (total == 0L) return 0f
        return (gapsDetected.toFloat() / total.toFloat()) * 100f
    }
}
