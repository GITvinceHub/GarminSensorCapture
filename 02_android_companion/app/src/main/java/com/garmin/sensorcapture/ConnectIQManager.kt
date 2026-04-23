package com.garmin.sensorcapture

import android.content.Context
import android.util.Log
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmin.android.connectiq.exception.InvalidStateException
import com.garmin.android.connectiq.exception.ServiceUnavailableException

private const val TAG = "ConnectIQManager"

/**
 * Singleton managing the Connect IQ Mobile SDK lifecycle.
 *
 * Responsibilities:
 * - Initialize and shutdown the SDK
 * - Discover paired Garmin devices
 * - Register listeners for app events
 * - Send messages to the watch
 *
 * Usage:
 *   ConnectIQManager.initialize(context, onReady = { ... }, onError = { ... })
 */
object ConnectIQManager {

    /** Connect IQ SDK instance */
    private var connectIQ: ConnectIQ? = null

    /** Application context (stored for later use) */
    private var appContext: Context? = null

    /** Callback fired when SDK is ready */
    private var onReadyCallback: (() -> Unit)? = null

    /** Callback fired when SDK initialization fails */
    private var onErrorCallback: ((String) -> Unit)? = null

    /** Whether the SDK is ready to use */
    @Volatile
    var isSdkReady: Boolean = false
        private set

    /**
     * Initialize the Connect IQ SDK.
     *
     * @param context     Application context
     * @param sdkType     SIMULATOR for testing, PRODUCTION for real devices
     * @param onReady     Called when SDK is initialized and ready
     * @param onError     Called if initialization fails
     */
    fun initialize(
        context: Context,
        sdkType: ConnectIQ.IQConnectType = ConnectIQ.IQConnectType.WIRELESS,
        onReady: () -> Unit,
        onError: (String) -> Unit
    ) {
        appContext       = context.applicationContext
        onReadyCallback  = onReady
        onErrorCallback  = onError

        connectIQ = ConnectIQ.getInstance(context, sdkType)

        connectIQ?.initialize(context, true, object : ConnectIQ.ConnectIQListener {

            override fun onSdkReady() {
                Log.d(TAG, "SDK ready")
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
                Log.d(TAG, "SDK shut down")
                isSdkReady = false
            }
        })
    }

    /**
     * Get the list of all paired and connected Garmin devices.
     *
     * @return List of IQDevice, empty if SDK not ready
     */
    fun getConnectedDevices(): List<IQDevice> {
        if (!isSdkReady || connectIQ == null) {
            Log.w(TAG, "getConnectedDevices: SDK not ready")
            return emptyList()
        }
        return try {
            connectIQ?.connectedDevices ?: emptyList()
        } catch (e: InvalidStateException) {
            Log.e(TAG, "getConnectedDevices InvalidStateException: ${e.message}")
            emptyList()
        } catch (e: ServiceUnavailableException) {
            Log.e(TAG, "getConnectedDevices ServiceUnavailableException: ${e.message}")
            emptyList()
        }
    }

    /**
     * Get the list of known (paired but possibly not connected) devices.
     *
     * @return List of IQDevice
     */
    fun getKnownDevices(): List<IQDevice> {
        if (!isSdkReady || connectIQ == null) return emptyList()
        return try {
            connectIQ?.knownDevices ?: emptyList()
        } catch (e: Exception) {
            Log.e(TAG, "getKnownDevices: ${e.message}")
            emptyList()
        }
    }

    /**
     * Register for application messages from the watch app.
     *
     * @param device   The target IQDevice
     * @param appId    UUID of the watch app (must match manifest.xml)
     * @param listener Callback for incoming messages
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
            Log.d(TAG, "Registered for app events: device=${device.friendlyName} app=$appId")
        } catch (e: InvalidStateException) {
            Log.e(TAG, "registerForAppEvents: ${e.message}")
        }
    }

    /**
     * Unregister from application events for a device.
     *
     * @param device The IQDevice to unregister from
     * @param appId  UUID of the watch app
     */
    fun unregisterForAppEvents(device: IQDevice, appId: String) {
        if (connectIQ == null) return
        try {
            val app = IQApp(appId)
            connectIQ?.unregisterForApplicationEvents(device, app)
        } catch (e: Exception) {
            Log.e(TAG, "unregisterForAppEvents: ${e.message}")
        }
    }

    /**
     * Send a message to the watch app.
     *
     * @param device   Target IQDevice
     * @param appId    UUID of the watch app
     * @param message  Message data (any serializable object, typically List<Any>)
     * @param listener Result listener
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
        } catch (e: InvalidStateException) {
            Log.e(TAG, "sendMessage InvalidStateException: ${e.message}")
        } catch (e: ServiceUnavailableException) {
            Log.e(TAG, "sendMessage ServiceUnavailableException: ${e.message}")
        }
    }

    /**
     * Register a device status listener (connected/disconnected events).
     *
     * @param device   The IQDevice to monitor
     * @param listener Status change callback
     */
    fun registerForDeviceEvents(
        device: IQDevice,
        listener: ConnectIQ.IQDeviceEventListener
    ) {
        if (!isSdkReady || connectIQ == null) return
        try {
            connectIQ?.registerForDeviceEvents(device, listener)
        } catch (e: Exception) {
            Log.e(TAG, "registerForDeviceEvents: ${e.message}")
        }
    }

    /**
     * Cleanly shut down the Connect IQ SDK.
     * Should be called from Application.onTerminate() or when app is destroyed.
     */
    fun cleanup() {
        try {
            connectIQ?.shutdown(appContext)
        } catch (e: Exception) {
            Log.e(TAG, "cleanup: ${e.message}")
        } finally {
            connectIQ  = null
            isSdkReady = false
            appContext  = null
        }
        Log.d(TAG, "Cleaned up")
    }

    /**
     * Get the raw ConnectIQ instance (for advanced use cases).
     */
    fun getInstance(): ConnectIQ? = connectIQ
}
