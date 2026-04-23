package com.garmin.sensorcapture

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Possible states of a capture session.
 */
enum class SessionState {
    IDLE,
    ACTIVE,
    STOPPING
}

/**
 * Immutable snapshot of session metadata.
 */
data class SessionInfo(
    val sessionId: String,
    val startedAt: Instant,
    val state: SessionState,
    val packetsReceived: Long = 0L
)

/**
 * Manages the capture session lifecycle on the Android side.
 *
 * Coordinates session state transitions and exposes session info
 * to ViewModel via StateFlow.
 */
class SessionManager {

    companion object {
        private const val DATE_FORMAT = "yyyyMMdd_HHmmss"
    }

    /** Current session state as observable flow */
    private val _sessionState = MutableStateFlow(SessionState.IDLE)
    val sessionState: StateFlow<SessionState> = _sessionState.asStateFlow()

    /** Current active session info (null if IDLE) */
    private val _sessionInfo = MutableStateFlow<SessionInfo?>(null)
    val sessionInfo: StateFlow<SessionInfo?> = _sessionInfo.asStateFlow()

    /** Packet counter for current session */
    @Volatile
    private var _packetsReceived: Long = 0L

    /**
     * Start a new capture session.
     * No-op if already active.
     *
     * @return The generated session ID, or null if not started
     */
    fun startSession(): String? {
        if (_sessionState.value != SessionState.IDLE) {
            return null
        }

        val sessionId = generateSessionId()
        val info = SessionInfo(
            sessionId    = sessionId,
            startedAt    = Instant.now(),
            state        = SessionState.ACTIVE,
            packetsReceived = 0L
        )

        _packetsReceived = 0L
        _sessionInfo.value = info
        _sessionState.value = SessionState.ACTIVE

        return sessionId
    }

    /**
     * Stop the current session gracefully.
     * Transitions to STOPPING then IDLE.
     */
    fun stopSession() {
        if (_sessionState.value != SessionState.ACTIVE) return

        _sessionState.value = SessionState.STOPPING
        _sessionInfo.value = _sessionInfo.value?.copy(state = SessionState.STOPPING)

        // Transition to IDLE after stop logic completes
        finalizeStop()
    }

    /**
     * Complete the stop transition (called after flush is done).
     */
    private fun finalizeStop() {
        _sessionState.value = SessionState.IDLE
        // Keep session info accessible until next session starts
    }

    /**
     * Increment packet counter (called by GarminReceiver on each packet).
     */
    fun onPacketReceived() {
        _packetsReceived++
        _sessionInfo.value = _sessionInfo.value?.copy(
            packetsReceived = _packetsReceived
        )
    }

    /**
     * Get the current session ID, or null if no active session.
     */
    fun getCurrentSessionId(): String? = _sessionInfo.value?.sessionId

    /**
     * Get total packets received in the current session.
     */
    fun getPacketsReceived(): Long = _packetsReceived

    /**
     * Check if a session is currently active.
     */
    fun isActive(): Boolean = _sessionState.value == SessionState.ACTIVE

    /**
     * Generate a unique session ID based on current UTC time.
     * Format: YYYYMMDD_HHMMSS
     */
    fun generateSessionId(): String {
        val now = Instant.now()
        val formatter = DateTimeFormatter
            .ofPattern(DATE_FORMAT)
            .withZone(ZoneOffset.UTC)
        return formatter.format(now)
    }
}
