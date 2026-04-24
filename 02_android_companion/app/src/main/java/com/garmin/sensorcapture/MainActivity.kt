package com.garmin.sensorcapture

import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Minimal UI activity wiring the SDK, GarminReceiver, FileLogger, SessionManager,
 * and ExportManager together.
 *
 * WATCH_APP_ID must match manifest.xml's applicationId on the watch side.
 */
class MainActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val WATCH_APP_ID = "a3b4c5d6-e7f8-1234-abcd-ef0123456789"
    }

    private val vm: MainViewModel by viewModels()

    private lateinit var sessionManager: SessionManager
    private lateinit var fileLogger: FileLogger
    private lateinit var exportManager: ExportManager
    private lateinit var receiver: GarminReceiver
    private val watchApp = IQApp(WATCH_APP_ID)

    @Volatile private var currentDevice: IQDevice? = null
    @Volatile private var listenerRegistered: Boolean = false

    // --- UI refs ---
    private lateinit var tvSdkStatus: TextView
    private lateinit var tvWatchStatus: TextView
    private lateinit var tvWatchId: TextView
    private lateinit var tvSessionId: TextView
    private lateinit var tvPackets: TextView
    private lateinit var tvFileSize: TextView
    private lateinit var tvThroughput: TextView
    private lateinit var tvLoss: TextView
    private lateinit var tvError: TextView
    private lateinit var btnStartStop: Button
    private lateinit var btnExportJsonl: Button
    private lateinit var btnExportZip: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        bindViews()

        sessionManager = SessionManager()
        fileLogger = FileLogger(this)
        exportManager = ExportManager(this)

        receiver = GarminReceiver(
            onPacketReceived = { pkt -> handlePacket(pkt) },
            onSendAck = { pi -> sendAck(pi) },
            onError = { msg -> vm.onError(msg) },
            onGapDetected = { expected, got ->
                Log.w(TAG, "Gap detected: expected $expected got $got")
            }
        )

        btnStartStop.setOnClickListener { toggleSession() }
        btnExportJsonl.setOnClickListener { exportJsonl() }
        btnExportZip.setOnClickListener { exportZip() }

        observeState()
        initSdk()
    }

    private fun bindViews() {
        tvSdkStatus = findViewById(R.id.tvSdkStatus)
        tvWatchStatus = findViewById(R.id.tvWatchStatus)
        tvWatchId = findViewById(R.id.tvWatchId)
        tvSessionId = findViewById(R.id.tvSessionId)
        tvPackets = findViewById(R.id.tvPackets)
        tvFileSize = findViewById(R.id.tvFileSize)
        tvThroughput = findViewById(R.id.tvThroughput)
        tvLoss = findViewById(R.id.tvLoss)
        tvError = findViewById(R.id.tvError)
        btnStartStop = findViewById(R.id.btnStartStop)
        btnExportJsonl = findViewById(R.id.btnExportJsonl)
        btnExportZip = findViewById(R.id.btnExportZip)
    }

    private fun observeState() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                vm.state.collectLatest { s ->
                    tvSdkStatus.text = "SDK: ${s.sdkStatus}"
                    tvWatchStatus.text = "Watch: ${s.watchStatus}"
                    tvWatchId.text = "ID: ${s.watchId ?: "-"}"
                    tvSessionId.text = "Session: ${s.sessionId ?: "-"}"
                    tvPackets.text = "Packets: ${s.packetsReceived}"
                    tvFileSize.text = "File: ${formatBytes(s.fileSizeBytes)}"
                    tvThroughput.text = String.format("Throughput: %.2f pkt/s", s.throughputPps)
                    tvLoss.text = String.format("Loss: %.1f%% (%d gaps)", s.packetLossPercent, s.gapsDetected)
                    if (s.lastError.isNullOrBlank()) {
                        tvError.visibility = View.GONE
                    } else {
                        tvError.visibility = View.VISIBLE
                        tvError.text = s.lastError
                    }
                    btnStartStop.text = if (s.sessionActive)
                        getString(R.string.stop_session) else getString(R.string.start_session)
                    val canExport = !s.sessionActive && s.sessionId != null
                    btnExportJsonl.isEnabled = canExport
                    btnExportZip.isEnabled = canExport
                }
            }
        }
    }

    private fun initSdk() {
        vm.updateSdkStatus("INITIALIZING")
        ConnectIQManager.initialize(
            this,
            onReady = {
                runOnUiThread {
                    vm.updateSdkStatus("READY")
                    discoverDevice()
                }
            },
            onError = { msg ->
                runOnUiThread {
                    vm.updateSdkStatus("ERROR")
                    vm.onError(msg)
                }
            }
        )
    }

    private fun discoverDevice() {
        val devices = ConnectIQManager.getConnectedDevices()
        if (devices.isEmpty()) {
            vm.updateWatchStatus("NOT_PAIRED", null)
            return
        }
        val dev = devices.first()
        currentDevice = dev
        vm.updateWatchStatus("CONNECTED", dev.deviceIdentifier.toString())

        // Register for app events so we start receiving packets.
        val ok = ConnectIQManager.registerForAppEvents(dev, watchApp, receiver)
        listenerRegistered = ok
        if (!ok) vm.onError("Failed to register for app events")

        ConnectIQManager.registerForDeviceEvents(dev, object : ConnectIQ.IQDeviceEventListener {
            override fun onDeviceStatusChanged(device: IQDevice?, status: IQDevice.IQDeviceStatus?) {
                runOnUiThread {
                    vm.updateWatchStatus(
                        status?.name ?: "UNKNOWN",
                        device?.deviceIdentifier?.toString()
                    )
                }
            }
        })
    }

    private fun toggleSession() {
        if (vm.state.value.sessionActive) {
            stopSession()
        } else {
            startSession()
        }
    }

    private fun startSession() {
        val sid = sessionManager.startSession()
        if (sid == null) {
            Toast.makeText(this, R.string.err_session_active, Toast.LENGTH_SHORT).show()
            return
        }
        vm.resetForNewSession()
        fileLogger.openSession(sid)
        vm.updateSessionState(true, sid)
    }

    private fun stopSession() {
        sessionManager.stopSession()
        fileLogger.flushAndClose()
        vm.updateSessionState(false, sessionManager.currentSessionId)
    }

    private fun handlePacket(packet: com.garmin.sensorcapture.models.GarminPacket) {
        // The packet's sid overrides our locally-generated sid.
        val pktSid = packet.sessionId
        if (!sessionManager.isActive && pktSid != null) {
            // Late packet after stop — still log but don't open a new session.
        }

        fileLogger.logPacket(packet)
        sessionManager.onPacketReceived()

        val received = sessionManager.packetsReceived
        val gaps = receiver.gapsDetected
        val lossPct: Double = if (received + gaps > 0L)
            100.0 * gaps.toDouble() / (received + gaps).toDouble() else 0.0

        vm.onPacketReceived(packet, fileLogger.getCurrentFileSize(), lossPct, gaps)
    }

    private fun sendAck(pi: Long) {
        val dev = currentDevice ?: return
        val payload = HashMap<String, Any>().apply { put("ack", pi.toInt()) }
        ConnectIQManager.sendMessage(
            dev,
            watchApp,
            payload,
            object : ConnectIQ.IQSendMessageListener {
                override fun onMessageStatus(
                    device: IQDevice?,
                    app: IQApp?,
                    status: ConnectIQ.IQMessageStatus?
                ) {
                    if (status != ConnectIQ.IQMessageStatus.SUCCESS) {
                        Log.w(TAG, "ACK pi=$pi status=$status")
                    }
                }
            }
        )
    }

    private fun exportJsonl() {
        val sid = sessionManager.currentSessionId
        if (sid == null) {
            Toast.makeText(this, R.string.err_no_data, Toast.LENGTH_SHORT).show()
            return
        }
        val uri = exportManager.exportJsonl(sid, fileLogger)
        if (uri == null) {
            Toast.makeText(this, R.string.err_export_failed, Toast.LENGTH_SHORT).show()
            return
        }
        exportManager.shareFile(uri, "application/json")
    }

    private fun exportZip() {
        val sid = sessionManager.currentSessionId
        if (sid == null) {
            Toast.makeText(this, R.string.err_no_data, Toast.LENGTH_SHORT).show()
            return
        }
        val uri = exportManager.exportZip(sid, fileLogger)
        if (uri == null) {
            Toast.makeText(this, R.string.err_export_failed, Toast.LENGTH_SHORT).show()
            return
        }
        exportManager.shareFile(uri, "application/zip")
    }

    override fun onDestroy() {
        try {
            if (listenerRegistered) {
                currentDevice?.let { ConnectIQManager.unregisterForAppEvents(it, watchApp) }
            }
            if (vm.state.value.sessionActive) {
                fileLogger.flushAndClose()
            }
            ConnectIQManager.cleanup(this)
        } catch (t: Throwable) {
            Log.e(TAG, "onDestroy cleanup failed", t)
        }
        super.onDestroy()
    }

    private fun formatBytes(b: Long): String {
        if (b < 1024) return "$b B"
        val kb = b / 1024.0
        if (kb < 1024) return String.format("%.1f KB", kb)
        val mb = kb / 1024.0
        return String.format("%.2f MB", mb)
    }
}
