package com.garmin.sensorcapture

import androidx.lifecycle.ViewModel
import com.garmin.sensorcapture.models.GarminPacket
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.util.ArrayDeque

/** Immutable UI snapshot surfaced to MainActivity. */
data class UiState(
    val sdkStatus: String        = "NOT_INITIALIZED",
    val watchStatus: String      = "UNKNOWN",
    val watchId: String          = "-",
    val packetsReceived: Long    = 0L,
    val fileSizeBytes: Long      = 0L,
    val throughputPps: Float     = 0f,
    val lastError: String?       = null,
    val sessionActive: Boolean   = false,
    val sessionId: String?       = null,
    val packetLossPercent: Float = 0f,
    val gapsDetected: Int        = 0,
    val batteryLevel: Int?       = null,
    val lastGpsFix: Boolean      = false
)

/**
 * UI state holder for [MainActivity].
 *
 * Exposes [UiState] via a [StateFlow] and computes a rolling throughput over a
 * 5-second window. All mutation goes through [update] so the flow always emits
 * a fresh immutable snapshot (required for Compose / lifecycleScope collectors).
 */
class MainViewModel : ViewModel() {

    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    /** Timestamps (ms) of the last N packets, for rolling throughput. */
    private val packetTimestamps = ArrayDeque<Long>()
    private val throughputWindowMs = 5_000L

    fun updateSdkStatus(status: String) {
        _uiState.update { it.copy(sdkStatus = status) }
    }

    fun updateWatchStatus(status: String, watchId: String = "-") {
        _uiState.update { it.copy(watchStatus = status, watchId = watchId) }
    }

    /**
     * Record a freshly received packet and refresh throughput.
     */
    fun onPacketReceived(
        packet: GarminPacket,
        fileSizeBytes: Long,
        lossPercent: Float,
        gaps: Int
    ) {
        val now = System.currentTimeMillis()

        packetTimestamps.addLast(now)
        while (packetTimestamps.isNotEmpty() &&
               now - packetTimestamps.first() > throughputWindowMs) {
            packetTimestamps.removeFirst()
        }

        val throughput: Float = if (packetTimestamps.size > 1) {
            val windowMs = (now - packetTimestamps.first()).coerceAtLeast(1L)
            packetTimestamps.size.toFloat() / (windowMs / 1000f)
        } else 0f

        val battery = packet.meta?.bat
        val hasGps  = packet.gps != null && packet.gps.isValid

        _uiState.update { s ->
            s.copy(
                packetsReceived   = s.packetsReceived + 1,
                fileSizeBytes     = fileSizeBytes,
                throughputPps     = throughput,
                batteryLevel      = battery ?: s.batteryLevel,
                lastGpsFix        = hasGps,
                packetLossPercent = lossPercent,
                gapsDetected      = gaps,
                lastError         = null
            )
        }
    }

    fun onError(message: String) {
        _uiState.update { it.copy(lastError = message) }
    }

    fun updateSessionState(active: Boolean, sessionId: String? = null) {
        if (!active) packetTimestamps.clear()
        _uiState.update { s ->
            s.copy(
                sessionActive = active,
                sessionId     = sessionId ?: s.sessionId,
                throughputPps = if (!active) 0f else s.throughputPps
            )
        }
    }

    fun resetForNewSession() {
        packetTimestamps.clear()
        _uiState.update { s ->
            s.copy(
                packetsReceived   = 0L,
                fileSizeBytes     = 0L,
                throughputPps     = 0f,
                lastError         = null,
                packetLossPercent = 0f,
                gapsDetected      = 0,
                lastGpsFix        = false
            )
        }
    }

    fun updateFileSize(bytes: Long) {
        _uiState.update { it.copy(fileSizeBytes = bytes) }
    }

    override fun onCleared() {
        super.onCleared()
        packetTimestamps.clear()
    }
}
