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
 * Receives and processes messages from the Garmin watch via Connect IQ.
 *
 * Implements IQApplicationEventListener to receive raw messages,
 * parses them as GarminPacket, validates them, and dispatches
 * to FileLogger and ViewModel.
 */
class GarminReceiver(
    private val fileLogger: FileLogger,
    private val sessionManager: SessionManager,
    private val onPacketReceived: (GarminPacket) -> Unit,
    private val onError: (String) -> Unit
) : ConnectIQ.IQApplicationEventListener {

    private val gson = Gson()

    /** Running count of valid packets received */
    @Volatile
    var validPacketsCount: Long = 0L
        private set

    /** Running count of invalid/parse-failed packets */
    @Volatile
    var invalidPacketsCount: Long = 0L
        private set

    /** Last received packet index (for gap detection) */
    @Volatile
    private var lastPacketIndex: Long = -1L

    /** Running count of detected gaps (missing packet indices) */
    @Volatile
    var gapsDetected: Int = 0
        private set

    /**
     * Called by Connect IQ SDK when a message arrives from the watch app.
     *
     * @param device       The source IQDevice
     * @param app          The source IQApp
     * @param messageData  Raw message data (typically List<Any?> containing a JSON string)
     * @param status       Message status
     */
    override fun onMessageReceived(
        device: IQDevice?,
        app: IQApp?,
        messageData: MutableList<Any>?,
        status: ConnectIQ.IQMessageStatus?
    ) {
        // Check status
        if (status != ConnectIQ.IQMessageStatus.SUCCESS) {
            val msg = "Message received with non-SUCCESS status: ${status?.name}"
            Log.w(TAG, msg)
            onError(msg)
            return
        }

        if (messageData == null) {
            Log.w(TAG, "Received null messageData")
            invalidPacketsCount++
            return
        }

        // Extract JSON string from messageData
        // Connect IQ SDK wraps messages in a List<Any?>, first element is the payload
        val jsonString = extractJsonString(messageData)
        if (jsonString == null) {
            Log.e(TAG, "Could not extract JSON string from message: ${messageData.javaClass.name}")
            invalidPacketsCount++
            onError("Unparseable message type: ${messageData.javaClass.simpleName}")
            return
        }

        // Parse and validate
        val packet = parsePacket(jsonString) ?: run {
            invalidPacketsCount++
            return
        }

        // Validate the packet
        if (!validatePacket(packet)) {
            Log.w(TAG, "Packet validation failed for pi=${packet.packetIndex}")
            invalidPacketsCount++
            return
        }

        // Detect gaps in packet sequence
        detectGaps(packet.packetIndex)

        // Log to file
        try {
            fileLogger.logPacket(packet)
        } catch (e: Exception) {
            Log.e(TAG, "FileLogger error: ${e.message}")
            onError("File write error: ${e.message}")
        }

        // Update session counter
        sessionManager.onPacketReceived()

        validPacketsCount++
        lastPacketIndex = packet.packetIndex

        // Dispatch to UI
        onPacketReceived(packet)

        Log.v(TAG, "Packet #${packet.packetIndex} received: ${packet.samples.size} samples")
    }

    /**
     * Extract the JSON string from Connect IQ message data.
     * The SDK wraps the payload in a List<Any?>, so we unwrap it.
     */
    private fun extractJsonString(messageData: Any?): String? {
        return when (messageData) {
            is String -> messageData
            is List<*> -> {
                // First element should be the JSON string
                when (val first = messageData.firstOrNull()) {
                    is String -> first
                    else -> messageData.firstOrNull()?.toString()
                }
            }
            else -> messageData?.toString()
        }
    }

    /**
     * Parse a JSON string into a GarminPacket.
     * Returns null on parse error.
     */
    private fun parsePacket(json: String): GarminPacket? {
        return try {
            gson.fromJson(json, GarminPacket::class.java)
        } catch (e: JsonSyntaxException) {
            Log.e(TAG, "JSON parse error: ${e.message} | JSON: ${json.take(200)}")
            onError("JSON parse error: ${e.message?.take(100)}")
            null
        } catch (e: Exception) {
            Log.e(TAG, "Unexpected parse error: ${e.message}")
            null
        }
    }

    /**
     * Validate that a packet has all required fields and sane values.
     */
    private fun validatePacket(packet: GarminPacket): Boolean {
        if (packet.protocolVersion != GarminPacket.PROTOCOL_VERSION_CURRENT) {
            Log.w(TAG, "Unknown protocol version: ${packet.protocolVersion}")
            // Attempt best-effort parsing anyway
        }

        if (packet.sessionId.isBlank()) {
            Log.w(TAG, "Packet has blank sessionId")
            return false
        }

        if (packet.packetIndex < 0) {
            Log.w(TAG, "Negative packetIndex: ${packet.packetIndex}")
            return false
        }

        if (packet.samples.isEmpty() && !packet.isPartial) {
            Log.w(TAG, "Packet has empty samples but no PARTIAL flag")
            // Not a hard failure — could be a keep-alive
        }

        if (packet.gps != null && !packet.gps.isValid) {
            Log.w(TAG, "Packet has invalid GPS coordinates: lat=${packet.gps.lat} lon=${packet.gps.lon}")
            // Not a hard failure — just a warning
        }

        return true
    }

    /**
     * Detect gaps in the packet sequence by tracking packet indices.
     */
    private fun detectGaps(currentIndex: Long) {
        if (lastPacketIndex >= 0 && currentIndex > lastPacketIndex + 1) {
            val gap = (currentIndex - lastPacketIndex - 1).toInt()
            gapsDetected += gap
            Log.w(TAG, "Gap detected: expected pi=${lastPacketIndex + 1} got pi=$currentIndex (gap=$gap)")
            onError("Packet gap: $gap packets lost before pi=$currentIndex")
        }
    }

    /**
     * Reset internal counters (call at start of new session).
     */
    fun reset() {
        validPacketsCount   = 0L
        invalidPacketsCount = 0L
        gapsDetected        = 0
        lastPacketIndex     = -1L
        Log.d(TAG, "Reset counters")
    }

    /**
     * Compute packet loss rate estimate.
     * @return Percentage (0-100) of estimated lost packets, or 0 if no data
     */
    fun getPacketLossPercent(): Float {
        val total = validPacketsCount + gapsDetected
        if (total == 0L) return 0f
        return (gapsDetected.toFloat() / total.toFloat()) * 100f
    }
}
