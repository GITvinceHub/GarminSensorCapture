package com.garmin.sensorcapture

import android.content.Context
import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice

private const val TAG = "ConnectIQManager"

/**
 * Singleton wrapper over the Connect IQ Mobile SDK.
 *
 * Implements contracts supporting C-060 per SPECIFICATION.md §7.7 (enables
 * [GarminReceiver] to receive messages and lets MainActivity relay ACKs
 * back to the watch — FR-010, FR-013).
 *
 * Design notes:
 *  - All SDK calls are defensively wrapped: the SDK is known to throw
 *    InvalidStateException or ServiceUnavailableException at surprising moments.
 *    We always catch Throwable per NFR-012.
 *  - [sendMessage] accepts any CIQ-serializable payload. For ACKs, callers pass
 *    a HashMap<String, Any> which the SDK CBOR-encodes as a Dictionary on the
 *    watch side.
 */
object ConnectIQManager {

    private var connectIQ: ConnectIQ? = null
    private var appContext: Context? = null

    /** True after the SDK signaled onSdkReady. */
    @Volatile
    var isSdkReady: Boolean = false
        private set

    /**
     * Initialize the SDK.
     *
     * @param context  application context
     * @param sdkType  WIRELESS (real watch) or TETHERED (USB sim)
     * @param onReady  fired on onSdkReady
     * @param onError  fired on onInitializeError
     */
    fun initialize(
        context: Context,
        sdkType: ConnectIQ.IQConnectType = ConnectIQ.IQConnectType.WIRELESS,
        onReady: () -> Unit,
        onError: (String) -> Unit
    ) {
        appContext = context.applicationContext
        try {
            connectIQ = ConnectIQ.getInstance(context, sdkType)
            connectIQ?.initialize(context, true, object : ConnectIQ.ConnectIQListener {
                override fun onSdkReady() {
                    Log.i(TAG, "SDK ready")
                    isSdkReady = true
                    onReady()
                }

                override fun onInitializeError(errStatus: ConnectIQ.IQSdkErrorStatus?) {
                    val msg = "SDK init error: ${errStatus?.name ?: "UNKNOWN"}"
                    Log.e(TAG, msg)
                    isSdkReady = false
                    onError(msg)
                }

                override fun onSdkShutDown() {
                    Log.i(TAG, "SDK shut down")
                    isSdkReady = false
                }
            })
        } catch (t: Throwable) {
            Log.e(TAG, "initialize threw: ${t.message}", t)
            isSdkReady = false
            onError("SDK init threw: ${t.message}")
        }
    }

    /** List of currently connected devices; empty if SDK not ready or on error. */
    fun getConnectedDevices(): List<IQDevice> {
        if (!isSdkReady || connectIQ == null) return emptyList()
        return try {
            connectIQ?.connectedDevices ?: emptyList()
        } catch (t: Throwable) {
            Log.e(TAG, "getConnectedDevices: ${t.message}")
            emptyList()
        }
    }

    /** List of paired but possibly disconnected devices. */
    fun getKnownDevices(): List<IQDevice> {
        if (!isSdkReady || connectIQ == null) return emptyList()
        return try {
            connectIQ?.knownDevices ?: emptyList()
        } catch (t: Throwable) {
            Log.e(TAG, "getKnownDevices: ${t.message}")
            emptyList()
        }
    }

    /**
     * Register a message listener for the given watch app.
     * Swallows all SDK exceptions — see NFR-012.
     */
    fun registerForAppEvents(
        device: IQDevice,
        appId: String,
        listener: ConnectIQ.IQApplicationEventListener
    ) {
        if (!isSdkReady || connectIQ == null) {
            Log.w(TAG, "registerForAppEvents: SDK not ready")
            return
        }
        try {
            val app = IQApp(appId)
            connectIQ?.registerForAppEvents(device, app, listener)
            Log.i(TAG, "Registered listener: device=${device.friendlyName} app=$appId")
        } catch (t: Throwable) {
            Log.e(TAG, "registerForAppEvents failed: ${t.message}", t)
        }
    }

    /** Unregister the app event listener. */
    fun unregisterForAppEvents(device: IQDevice, appId: String) {
        if (connectIQ == null) return
        try {
            val app = IQApp(appId)
            connectIQ?.unregisterForApplicationEvents(device, app)
        } catch (t: Throwable) {
            Log.e(TAG, "unregisterForAppEvents failed: ${t.message}")
        }
    }

    /**
     * Send a message to the watch app.
     *
     * For ACK messages (FR-013), [message] should be a HashMap<String, Any>
     * shaped like `{"ack": packetIndex}`. The SDK serializes it to CBOR and
     * the watch receives it as a CIQ Dictionary.
     */
    fun sendMessage(
        device: IQDevice,
        appId: String,
        message: Any,
        listener: ConnectIQ.IQSendMessageListener
    ) {
        if (!isSdkReady || connectIQ == null) {
            Log.w(TAG, "sendMessage: SDK not ready")
            return
        }
        try {
            val app = IQApp(appId)
            connectIQ?.sendMessage(device, app, message, listener)
        } catch (t: Throwable) {
            Log.e(TAG, "sendMessage failed: ${t.message}", t)
        }
    }

    /** Register for device connection / disconnection events. */
    fun registerForDeviceEvents(
        device: IQDevice,
        listener: ConnectIQ.IQDeviceEventListener
    ) {
        if (!isSdkReady || connectIQ == null) return
        try {
            connectIQ?.registerForDeviceEvents(device, listener)
        } catch (t: Throwable) {
            Log.e(TAG, "registerForDeviceEvents failed: ${t.message}")
        }
    }

    /** Shut down the SDK. Safe to call multiple times. */
    fun cleanup() {
        try {
            connectIQ?.shutdown(appContext)
        } catch (t: Throwable) {
            Log.e(TAG, "cleanup failed: ${t.message}")
        } finally {
            connectIQ  = null
            isSdkReady = false
            appContext = null
        }
    }

    /** Raw SDK handle, for advanced use. */
    fun getInstance(): ConnectIQ? = connectIQ
}
