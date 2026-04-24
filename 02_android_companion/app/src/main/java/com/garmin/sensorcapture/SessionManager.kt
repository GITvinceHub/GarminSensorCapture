package com.garmin.sensorcapture

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** Possible states for the Android-side session tracker. */
enum class SessionState { IDLE, ACTIVE, STOPPING }

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
 * Android-side session tracker.
 *
 * Mirrors the watch's session FSM (SPECIFICATION.md §6.2 on a smaller scope —
 * the Android side doesn't need the STOPPING flush ceremony). Invariant INV-002
 * (unique sessionId) is honoured by [generateSessionId] using UTC seconds.
 */
class SessionManager {

    companion object {
        private const val DATE_FORMAT = "yyyyMMdd_HHmmss"
    }

    private val _sessionState = MutableStateFlow(SessionState.IDLE)
    val sessionState: StateFlow<SessionState> = _sessionState.asStateFlow()

    private val _sessionInfo = MutableStateFlow<SessionInfo?>(null)
    val sessionInfo: StateFlow<SessionInfo?> = _sessionInfo.asStateFlow()

    @Volatile
    private var _packetsReceived: Long = 0L

    /**
     * Start a new session.
     * @return the new session ID, or null if a session is already running.
     */
    fun startSession(): String? {
        if (_sessionState.value != SessionState.IDLE) return null

        val sessionId = generateSessionId()
        _packetsReceived = 0L
        _sessionInfo.value = SessionInfo(
            sessionId       = sessionId,
            startedAt       = Instant.now(),
            state           = SessionState.ACTIVE,
            packetsReceived = 0L
        )
        _sessionState.value = SessionState.ACTIVE
        return sessionId
    }

    /**
     * Stop the session.
     * Transitions ACTIVE → STOPPING → IDLE. No-op if not active.
     */
    fun stopSession() {
        if (_sessionState.value != SessionState.ACTIVE) return
        _sessionState.value = SessionState.STOPPING
        _sessionInfo.value = _sessionInfo.value?.copy(state = SessionState.STOPPING)
        _sessionState.value = SessionState.IDLE
        _sessionInfo.value = _sessionInfo.value?.copy(state = SessionState.IDLE)
    }

    /** Increment the packet counter. Thread-safe via [MutableStateFlow]. */
    fun onPacketReceived() {
        _packetsReceived++
        _sessionInfo.value = _sessionInfo.value?.copy(packetsReceived = _packetsReceived)
    }

    fun getCurrentSessionId(): String? = _sessionInfo.value?.sessionId
    fun getPacketsReceived(): Long     = _packetsReceived
    fun isActive(): Boolean            = _sessionState.value == SessionState.ACTIVE

    /**
     * INV-002: unique session ID based on UTC second. Format: yyyyMMdd_HHmmss.
     */
    fun generateSessionId(): String {
        val formatter = DateTimeFormatter
            .ofPattern(DATE_FORMAT)
            .withZone(ZoneOffset.UTC)
        return formatter.format(Instant.now())
    }
}
