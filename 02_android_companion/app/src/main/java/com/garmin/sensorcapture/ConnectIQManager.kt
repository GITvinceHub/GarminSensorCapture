package com.garmin.sensorcapture

import android.content.Context
import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmin.android.connectiq.exception.InvalidStateException
import com.garmin.android.connectiq.exception.ServiceUnavailableException

/**
 * Singleton wrapper around Connect IQ Mobile SDK.
 *
 * Every SDK call is wrapped in try/catch(Throwable) — the SDK is known to throw
 * LinkageError and raw RuntimeExceptions on mobile-side BLE glitches.
 *
 * @see SPECIFICATION.md §7.7, NFR-012
 */
object ConnectIQManager {
    private const val TAG = "ConnectIQManager"

    @Volatile
    private var connectIQ: ConnectIQ? = null

    @Volatile
    private var initialized: Boolean = false

    /**
     * Initialize the SDK with WIRELESS connection type.
     *
     * @param onReady invoked on success
     * @param onError invoked on any failure (SDK error, service unavailable, etc.)
     */
    fun initialize(
        context: Context,
        onReady: () -> Unit,
        onError: (String) -> Unit
    ) {
        try {
            val instance = ConnectIQ.getInstance(
                context.applicationContext,
                ConnectIQ.IQConnectType.WIRELESS
            )
            connectIQ = instance
            instance.initialize(
                context.applicationContext,
                true,
                object : ConnectIQ.ConnectIQListener {
                    override fun onSdkReady() {
                        initialized = true
                        try {
                            onReady()
                        } catch (t: Throwable) {
                            Log.e(TAG, "onReady callback threw", t)
                        }
                    }

                    override fun onInitializeError(errStatus: ConnectIQ.IQSdkErrorStatus?) {
                        initialized = false
                        try {
                            onError("SDK init error: $errStatus")
                        } catch (t: Throwable) {
                            Log.e(TAG, "onError callback threw", t)
                        }
                    }

                    override fun onSdkShutDown() {
                        initialized = false
                        Log.w(TAG, "SDK shutdown")
                    }
                }
            )
        } catch (t: Throwable) {
            Log.e(TAG, "initialize() failed", t)
            try {
                onError("initialize() exception: ${t.message}")
            } catch (_: Throwable) {
                // swallow
            }
        }
    }

    /** Returns list of paired/connected devices, or empty list on error. */
    fun getConnectedDevices(): List<IQDevice> {
        val iq = connectIQ ?: return emptyList()
        return try {
            iq.connectedDevices ?: emptyList()
        } catch (t: Throwable) {
            Log.e(TAG, "getConnectedDevices failed", t)
            emptyList()
        }
    }

    /** Register for app events (incoming messages from watch app). */
    fun registerForAppEvents(
        device: IQDevice,
        app: IQApp,
        listener: ConnectIQ.IQApplicationEventListener
    ): Boolean {
        val iq = connectIQ ?: return false
        return try {
            iq.registerForAppEvents(device, app, listener)
            true
        } catch (t: Throwable) {
            Log.e(TAG, "registerForAppEvents failed", t)
            false
        }
    }

    /** Unregister app events listener. Silent on error. */
    fun unregisterForAppEvents(device: IQDevice, app: IQApp) {
        val iq = connectIQ ?: return
        try {
            iq.unregisterForApplicationEvents(device, app)
        } catch (t: Throwable) {
            Log.e(TAG, "unregisterForAppEvents failed", t)
        }
    }

    /**
     * Send a message to the watch app (e.g. ACK payload).
     *
     * @param payload typically `HashMap<String,Any>{"ack" to pi.toInt()}`
     * @return true if the SDK accepted the call (NOT a delivery guarantee)
     */
    fun sendMessage(
        device: IQDevice,
        app: IQApp,
        payload: Any,
        listener: ConnectIQ.IQSendMessageListener
    ): Boolean {
        val iq = connectIQ ?: return false
        return try {
            iq.sendMessage(device, app, payload, listener)
            true
        } catch (e: InvalidStateException) {
            Log.e(TAG, "sendMessage invalid state", e)
            false
        } catch (e: ServiceUnavailableException) {
            Log.e(TAG, "sendMessage service unavailable", e)
            false
        } catch (t: Throwable) {
            Log.e(TAG, "sendMessage failed", t)
            false
        }
    }

    /** Register for device-level connectivity changes. */
    fun registerForDeviceEvents(
        device: IQDevice,
        listener: ConnectIQ.IQDeviceEventListener
    ): Boolean {
        val iq = connectIQ ?: return false
        return try {
            iq.registerForDeviceEvents(device, listener)
            true
        } catch (t: Throwable) {
            Log.e(TAG, "registerForDeviceEvents failed", t)
            false
        }
    }

    /** Fully shut down the SDK. Safe to call multiple times. */
    fun cleanup(context: Context) {
        val iq = connectIQ ?: return
        try {
            iq.shutdown(context.applicationContext)
        } catch (t: Throwable) {
            Log.e(TAG, "cleanup failed", t)
        } finally {
            connectIQ = null
            initialized = false
        }
    }

    fun isInitialized(): Boolean = initialized
}
