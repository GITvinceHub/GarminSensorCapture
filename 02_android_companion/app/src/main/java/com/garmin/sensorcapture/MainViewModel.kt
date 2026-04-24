package com.garmin.sensorcapture

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.garmin.sensorcapture.models.GarminPacket
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.ArrayDeque

/**
 * Aggregated UI state for MainActivity.
 *
 *  - throughputPps: 5-second rolling average, updated on every packet
 *  - packetLossPercent / gapsDetected: supplied by GarminReceiver
 */
class MainViewModel(app: Application) : AndroidViewModel(app) {

    data class UiState(
        val sdkStatus: String = "NOT_INITIALIZED",
        val watchStatus: String = "UNKNOWN",
        val watchId: String? = null,
        val sessionActive: Boolean = false,
        val sessionId: String? = null,
        val packetsReceived: Long = 0L,
        val fileSizeBytes: Long = 0L,
        val throughputPps: Double = 0.0,
        val packetLossPercent: Double = 0.0,
        val gapsDetected: Long = 0L,
        val lastError: String? = null
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    /** Packet-reception timestamps for rolling 5-second throughput. */
    private val recentReceiveMs = ArrayDeque<Long>()
    private val rollingWindowMs = 5_000L

    fun updateSdkStatus(status: String) {
        _state.value = _state.value.copy(sdkStatus = status)
    }

    fun updateWatchStatus(status: String, id: String?) {
        _state.value = _state.value.copy(watchStatus = status, watchId = id)
    }

    fun updateSessionState(active: Boolean, sessionId: String?) {
        _state.value = _state.value.copy(sessionActive = active, sessionId = sessionId)
    }

    /** Reset counters for a fresh session (packetsReceived, throughput, loss, error). */
    fun resetForNewSession() {
        synchronized(recentReceiveMs) { recentReceiveMs.clear() }
        _state.value = _state.value.copy(
            packetsReceived = 0L,
            fileSizeBytes = 0L,
            throughputPps = 0.0,
            packetLossPercent = 0.0,
            gapsDetected = 0L,
            lastError = null
        )
    }

    fun onPacketReceived(
        @Suppress("UNUSED_PARAMETER") packet: GarminPacket,
        fileSizeBytes: Long,
        lossPercent: Double,
        gaps: Long
    ) {
        val now = System.currentTimeMillis()
        val pps: Double = synchronized(recentReceiveMs) {
            recentReceiveMs.addLast(now)
            while (recentReceiveMs.isNotEmpty()) {
                val head = recentReceiveMs.peekFirst() ?: break
                if (now - head <= rollingWindowMs) break
                recentReceiveMs.pollFirst()
            }
            val count = recentReceiveMs.size.toDouble()
            val first: Long = recentReceiveMs.peekFirst() ?: now
            val spanMs = (now - first).coerceAtLeast(1L)
            // Effective window: either the full 5s or the span we actually have.
            val denomMs = minOf(spanMs, rollingWindowMs).toDouble()
            if (denomMs <= 0.0) 0.0 else count * 1000.0 / denomMs
        }

        val prev = _state.value
        _state.value = prev.copy(
            packetsReceived = prev.packetsReceived + 1,
            fileSizeBytes = fileSizeBytes,
            throughputPps = pps,
            packetLossPercent = lossPercent,
            gapsDetected = gaps
        )
    }

    fun onError(msg: String) {
        _state.value = _state.value.copy(lastError = msg)
    }
}
