package com.garmin.sensorcapture

import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmin.sensorcapture.models.GarminPacket
import com.google.gson.Gson
import com.google.gson.JsonSyntaxException

/**
 * Listener for inbound messages from the watch app.
 *
 * Contracts (SPEC §7.7):
 *  - C-060 onMessageReceived — never let an exception escape (outer catch Throwable,
 *    not Exception — survive LinkageError / OOM mid-BLE). Ack ONLY data packets.
 *  - C-061 validatePacket — sid non-blank, pi >= 0, samples non-empty for data,
 *    nullable-safe via isNullOrEmpty.
 *
 * Also implements SC-002 (header packet must NEVER crash — isMetaPacket short-circuits
 * sample validation) and SC-010 (callback exceptions must not kill the app).
 */
class GarminReceiver(
    private val onPacketReceived: (GarminPacket) -> Unit,
    /** Called ONLY for valid data packets (INV-006). Argument = packetIndex to ack. */
    private val onSendAck: (Long) -> Unit,
    private val onError: (String) -> Unit,
    private val onGapDetected: ((expected: Long, got: Long) -> Unit)? = null
) : ConnectIQ.IQApplicationEventListener {

    companion object {
        private const val TAG = "GarminReceiver"
    }

    private val gson = Gson()

    @Volatile private var lastPacketIndex: Long = -1L
    @Volatile var invalidPacketsCount: Long = 0L
        private set
    @Volatile var gapsDetected: Long = 0L
        private set
    @Volatile var totalReceived: Long = 0L
        private set

    override fun onMessageReceived(
        device: IQDevice?,
        app: IQApp?,
        messageData: MutableList<Any>?,
        status: ConnectIQ.IQMessageStatus?
    ) {
        // OUTER catch Throwable — we must survive LinkageError / OOM / anything.
        try {
            if (status != ConnectIQ.IQMessageStatus.SUCCESS) {
                invalidPacketsCount++
                safeOnError("Non-success status: $status")
                return
            }

            if (messageData.isNullOrEmpty()) {
                invalidPacketsCount++
                safeOnError("Empty messageData")
                return
            }

            for (msg in messageData) {
                processOne(msg)
            }
        } catch (t: Throwable) {
            // Last line of defence.
            invalidPacketsCount++
            Log.e(TAG, "onMessageReceived FATAL", t)
            safeOnError("onMessageReceived threw: ${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun processOne(msg: Any?) {
        if (msg == null) {
            invalidPacketsCount++
            return
        }

        val packet: GarminPacket? = try {
            when (msg) {
                is String -> parseJson(msg)
                is Map<*, *> -> {
                    // CIQ can deliver a Dictionary directly — reserialize through Gson.
                    val json = gson.toJson(msg)
                    parseJson(json)
                }
                else -> {
                    // Unknown shape — try toString() as a last resort.
                    parseJson(msg.toString())
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Parse threw: ${t.message}")
            null
        }

        if (packet == null) {
            invalidPacketsCount++
            safeOnError("Parse failed / null packet")
            return
        }

        if (!validatePacket(packet)) {
            invalidPacketsCount++
            safeOnError("Validation failed: sid=${packet.sessionId} pi=${packet.packetIndex} meta=${packet.isMetaPacket}")
            return
        }

        totalReceived++

        // Gap detection (only for data packets — meta can arrive at pi=0 out of order).
        if (!packet.isMetaPacket) {
            val pi = packet.packetIndex ?: -1L
            if (lastPacketIndex >= 0 && pi > lastPacketIndex + 1) {
                val gapSize = pi - lastPacketIndex - 1
                gapsDetected += gapSize
                try {
                    onGapDetected?.invoke(lastPacketIndex + 1, pi)
                } catch (t: Throwable) {
                    Log.e(TAG, "onGapDetected threw", t)
                }
            }
            if (pi > lastPacketIndex) lastPacketIndex = pi
        }

        // Dispatch to logger/UI BEFORE ack so the file is written first.
        try {
            onPacketReceived(packet)
        } catch (t: Throwable) {
            Log.e(TAG, "onPacketReceived callback threw", t)
            safeOnError("onPacketReceived threw: ${t.message}")
        }

        // INV-006 — never ACK meta packets. FR-013 — ACK every data packet.
        if (!packet.isMetaPacket) {
            val pi = packet.packetIndex
            if (pi != null && pi >= 0) {
                try {
                    onSendAck(pi)
                } catch (t: Throwable) {
                    Log.e(TAG, "onSendAck threw", t)
                    safeOnError("ACK send threw: ${t.message}")
                }
            }
        }
    }

    private fun parseJson(json: String?): GarminPacket? {
        if (json.isNullOrBlank()) return null
        return try {
            gson.fromJson(json, GarminPacket::class.java)
        } catch (e: JsonSyntaxException) {
            Log.w(TAG, "JSON syntax: ${e.message}")
            null
        } catch (t: Throwable) {
            Log.w(TAG, "JSON parse error: ${t.message}")
            null
        }
    }

    /**
     * C-061 — returns true if valid, false otherwise. NEVER throws.
     * Meta packets skip the samples-non-empty check (SC-002 / FR-014).
     */
    fun validatePacket(packet: GarminPacket): Boolean {
        return try {
            val sid = packet.sessionId
            if (sid.isNullOrBlank()) return false

            val pi = packet.packetIndex ?: return false
            if (pi < 0L) return false

            if (packet.isMetaPacket) {
                // meta: samples may be null/empty
                true
            } else {
                // data: samples must be non-empty (nullable-safe)
                !packet.samples.isNullOrEmpty()
            }
        } catch (t: Throwable) {
            Log.e(TAG, "validatePacket threw (returning false)", t)
            false
        }
    }

    private fun safeOnError(msg: String) {
        try {
            onError(msg)
        } catch (t: Throwable) {
            Log.e(TAG, "onError callback threw", t)
        }
    }
}
