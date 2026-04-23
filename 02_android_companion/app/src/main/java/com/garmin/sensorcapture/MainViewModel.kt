package com.garmin.sensorcapture

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.garmin.sensorcapture.models.GarminPacket
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.LinkedList

/**
 * Immutable UI state snapshot.
 */
data class UiState(
    val sdkStatus: String          = "NOT_INITIALIZED",
    val watchStatus: String        = "UNKNOWN",
    val watchId: String            = "-",
    val packetsReceived: Long      = 0L,
    val fileSizeBytes: Long        = 0L,
    val throughputPps: Float       = 0f,     // packets per second (rolling 5s window)
    val lastError: String?         = null,
    val sessionActive: Boolean     = false,
    val sessionId: String?         = null,
    val packetLossPercent: Float   = 0f,
    val gapsDetected: Int          = 0,
    val batteryLevel: Int?         = null,
    val lastGpsFix: Boolean        = false
)

/**
 * ViewModel for MainActivity.
 *
 * Exposes UiState via StateFlow.
 * Computes rolling throughput over a 5-second window.
 */
class MainViewModel : ViewModel() {

    /** Public read-only state */
    private val _uiState = MutableStateFlow(UiState())
    val uiState: StateFlow<UiState> = _uiState.asStateFlow()

    // ── Throughput computation ────────────────────────────────────────
    /** Timestamps (System.currentTimeMillis) of the last N packets, for throughput */
    private val packetTimestamps = LinkedList<Long>()
    private val THROUGHPUT_WINDOW_MS = 5_000L

    // ── Public update functions ───────────────────────────────────────

    /**
     * Update Connect IQ SDK readiness status.
     * @param status Human-readable status string (e.g., "READY", "ERROR: ...")
     */
    fun updateSdkStatus(status: String) {
        _uiState.update { it.copy(sdkStatus = status) }
    }

    /**
     * Update the watch connection status.
     * @param status e.g., "CONNECTED", "DISCONNECTED", "NOT_PAIRED"
     * @param watchId Friendly name or ID of the watch, empty if unknown
     */
    fun updateWatchStatus(status: String, watchId: String = "-") {
        _uiState.update { it.copy(watchStatus = status, watchId = watchId) }
    }

    /**
     * Called when a new packet is received.
     * Updates counters, computes throughput, updates file size.
     *
     * @param packet      The received packet
     * @param fileSizeBytes Current size of the JSONL file
     * @param lossPercent Current packet loss estimate
     * @param gaps        Total gap count
     */
    fun onPacketReceived(
        packet: GarminPacket,
        fileSizeBytes: Long,
        lossPercent: Float,
        gaps: Int
    ) {
        val now = System.currentTimeMillis()

        // Add timestamp to rolling window
        packetTimestamps.addLast(now)

        // Remove timestamps older than the window
        while (packetTimestamps.isNotEmpty() &&
               now - packetTimestamps.first > THROUGHPUT_WINDOW_MS) {
            packetTimestamps.removeFirst()
        }

        // Compute throughput
        val throughput = if (packetTimestamps.size > 1) {
            val windowDuration = (now - packetTimestamps.first).coerceAtLeast(1L)
            packetTimestamps.size.toFloat() / (windowDuration / 1000f)
        } else {
            0f
        }

        // Extract battery if available
        val battery = packet.meta?.bat

        // GPS fix available?
        val hasGps = packet.gps != null && packet.gps.isValid

        _uiState.update { state ->
            state.copy(
                packetsReceived    = state.packetsReceived + 1,
                fileSizeBytes      = fileSizeBytes,
                throughputPps      = throughput,
                batteryLevel       = battery ?: state.batteryLevel,
                lastGpsFix         = hasGps,
                packetLossPercent  = lossPercent,
                gapsDetected       = gaps,
                lastError          = null  // Clear last error on successful packet
            )
        }
    }

    /**
     * Record an error for display in the UI.
     * @param message Error message string
     */
    fun onError(message: String) {
        _uiState.update { it.copy(lastError = message) }
    }

    /**
     * Update session active state.
     * @param active true if session is running
     * @param sessionId The current session ID (or null)
     */
    fun updateSessionState(active: Boolean, sessionId: String? = null) {
        if (!active) {
            packetTimestamps.clear()
        }
        _uiState.update { state ->
            state.copy(
                sessionActive = active,
                sessionId     = sessionId,
                throughputPps = if (!active) 0f else state.throughputPps
            )
        }
    }

    /**
     * Reset all session-specific counters for a new session.
     */
    fun resetForNewSession() {
        packetTimestamps.clear()
        _uiState.update { state ->
            state.copy(
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

    /**
     * Update the displayed file size (e.g., from a periodic refresh).
     */
    fun updateFileSize(bytes: Long) {
        _uiState.update { it.copy(fileSizeBytes = bytes) }
    }

    override fun onCleared() {
        super.onCleared()
        packetTimestamps.clear()
    }
}
