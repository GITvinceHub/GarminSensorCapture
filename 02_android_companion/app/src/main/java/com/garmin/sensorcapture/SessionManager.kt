package com.garmin.sensorcapture

import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicLong

/**
 * Android-side session tracker. This is distinct from the watch's SessionManager —
 * here we only care about file-level bookkeeping: unique sid, start/stop state,
 * packets received counter.
 *
 * The watch is authoritative for session IDs (sid arrives in every packet), but
 * the Android side can also start a session locally before the first packet —
 * the sid generated here is used for the JSONL filename in that case, and the
 * first packet's sid will override if different.
 */
class SessionManager {

    companion object {
        private const val TAG = "SessionManager"
    }

    private val dateFormatter = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    @Volatile var currentSessionId: String? = null
        private set
    @Volatile var isActive: Boolean = false
        private set

    private val _packetsReceived = AtomicLong(0L)
    val packetsReceived: Long get() = _packetsReceived.get()

    /**
     * Start a new session. Returns the new sid, or null if already active.
     */
    @Synchronized
    fun startSession(): String? {
        if (isActive) {
            Log.w(TAG, "startSession: already active (sid=$currentSessionId)")
            return null
        }
        val sid = dateFormatter.format(Date())
        currentSessionId = sid
        isActive = true
        _packetsReceived.set(0L)
        return sid
    }

    /** Stop the current session. Idempotent. */
    @Synchronized
    fun stopSession() {
        isActive = false
    }

    /** Called by MainActivity/ViewModel each time GarminReceiver delivers a valid packet. */
    fun onPacketReceived() {
        _packetsReceived.incrementAndGet()
    }
}
