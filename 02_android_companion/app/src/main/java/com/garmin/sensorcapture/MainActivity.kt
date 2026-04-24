package com.garmin.sensorcapture

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import kotlinx.coroutines.launch

private const val TAG = "MainActivity"

/** Matches the watch manifest.xml UUID. SPECIFICATION.md §12.1. */
private const val WATCH_APP_ID = "a3b4c5d6-e7f8-1234-abcd-ef0123456789"

/**
 * Top-level Android activity for GarminSensorCapture.
 *
 * Coordinates:
 *  - Connect IQ SDK initialisation
 *  - Device discovery and connection monitoring
 *  - Session start/stop and GarminReceiver lifecycle
 *  - ACK relay back to the watch for each data packet (FR-013 / INV-006)
 *  - Export via share sheet (FR-043 / NFR-022)
 *
 * See SPECIFICATION.md §4.4, §7.7 for the contracts realised here.
 */
class MainActivity : AppCompatActivity() {

    private val viewModel: MainViewModel by viewModels()

    private lateinit var sessionManager: SessionManager
    private lateinit var fileLogger: FileLogger
    private lateinit var exportManager: ExportManager
    private var garminReceiver: GarminReceiver? = null

    private var connectedDevice: IQDevice? = null

    // ── UI ─────────────────────────────────────────────────────────────
    private lateinit var tvSdkStatus: TextView
    private lateinit var tvWatchStatus: TextView
    private lateinit var tvWatchId: TextView
    private lateinit var tvPackets: TextView
    private lateinit var tvFileSize: TextView
    private lateinit var tvThroughput: TextView
    private lateinit var tvError: TextView
    private lateinit var tvSessionId: TextView
    private lateinit var tvLoss: TextView
    private lateinit var btnStartStop: Button
    private lateinit var btnExportJsonl: Button
    private lateinit var btnExportZip: Button
    private lateinit var scrollView: ScrollView

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) {
            initConnectIQ()
        } else {
            Toast.makeText(this, "Bluetooth permissions required", Toast.LENGTH_LONG).show()
            Log.w(TAG, "Permissions denied: $permissions")
        }
    }

    // ────────────────────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        bindViews()
        setupManagers()
        setupButtons()
        observeViewModel()
        requestPermissionsIfNeeded()
    }

    private fun bindViews() {
        tvSdkStatus    = findViewById(R.id.tvSdkStatus)
        tvWatchStatus  = findViewById(R.id.tvWatchStatus)
        tvWatchId      = findViewById(R.id.tvWatchId)
        tvPackets      = findViewById(R.id.tvPackets)
        tvFileSize     = findViewById(R.id.tvFileSize)
        tvThroughput   = findViewById(R.id.tvThroughput)
        tvError        = findViewById(R.id.tvError)
        tvSessionId    = findViewById(R.id.tvSessionId)
        tvLoss         = findViewById(R.id.tvLoss)
        btnStartStop   = findViewById(R.id.btnStartStop)
        btnExportJsonl = findViewById(R.id.btnExportJsonl)
        btnExportZip   = findViewById(R.id.btnExportZip)
        scrollView     = findViewById(R.id.scrollView)
    }

    private fun setupManagers() {
        sessionManager = SessionManager()
        fileLogger     = FileLogger(applicationContext)
        exportManager  = ExportManager(applicationContext)
    }

    private fun setupButtons() {
        btnStartStop.setOnClickListener {
            if (viewModel.uiState.value.sessionActive) stopSession() else startSession()
        }
        btnExportJsonl.setOnClickListener { exportJsonl() }
        btnExportZip.setOnClickListener   { exportZip() }
    }

    private fun observeViewModel() {
        lifecycleScope.launch {
            viewModel.uiState.collect(::updateUi)
        }
    }

    private fun updateUi(state: UiState) {
        tvSdkStatus.text   = "SDK: ${state.sdkStatus}"
        tvWatchStatus.text = "Watch: ${state.watchStatus}"
        tvWatchId.text     = "ID: ${state.watchId}"
        tvPackets.text     = "Packets: ${state.packetsReceived}"
        tvFileSize.text    = "File: ${formatBytes(state.fileSizeBytes)}"
        tvThroughput.text  = "Throughput: ${"%.2f".format(state.throughputPps)} pkt/s"
        tvSessionId.text   = "Session: ${state.sessionId ?: "-"}"
        tvLoss.text        = "Loss: ${"%.1f".format(state.packetLossPercent)}% (${state.gapsDetected} gaps)"

        if (state.lastError != null) {
            tvError.text       = "ERR: ${state.lastError}"
            tvError.visibility = View.VISIBLE
        } else {
            tvError.visibility = View.GONE
        }

        btnStartStop.text = if (state.sessionActive) "Stop Session" else "Start Session"
        btnExportJsonl.isEnabled = !state.sessionActive && state.packetsReceived > 0
        btnExportZip.isEnabled   = !state.sessionActive && state.packetsReceived > 0
    }

    // ── Session control ──────────────────────────────────────────────

    private fun startSession() {
        val device = connectedDevice ?: run {
            Toast.makeText(this, "No watch connected", Toast.LENGTH_SHORT).show()
            return
        }

        val sessionId = sessionManager.startSession() ?: run {
            Toast.makeText(this, "Session already active", Toast.LENGTH_SHORT).show()
            return
        }

        viewModel.resetForNewSession()
        viewModel.updateSessionState(true, sessionId)

        fileLogger.openSession(sessionId)

        garminReceiver = GarminReceiver(
            fileLogger     = fileLogger,
            sessionManager = sessionManager,
            onPacketReceived = { packet ->
                runOnUiThread {
                    viewModel.onPacketReceived(
                        packet        = packet,
                        fileSizeBytes = fileLogger.getCurrentFileSize(),
                        lossPercent   = garminReceiver?.getPacketLossPercent() ?: 0f,
                        gaps          = garminReceiver?.gapsDetected ?: 0
                    )
                }
            },
            onError = { msg -> runOnUiThread { viewModel.onError(msg) } },
            // FR-013 / INV-006: ACK DATA packets only; GarminReceiver already
            // filters out meta packets before invoking this callback.
            onSendAck = { packetIndex -> sendAck(packetIndex) }
        )

        ConnectIQManager.registerForAppEvents(device, WATCH_APP_ID, garminReceiver!!)
        Log.i(TAG, "Session started: $sessionId")
    }

    /**
     * Send `{"ack": <packetIndex>}` to the watch.
     * The CIQ SDK CBOR-encodes the HashMap → the watch receives a Dictionary.
     */
    private fun sendAck(packetIndex: Long) {
        val device = connectedDevice ?: return
        val ackMsg = HashMap<String, Any>().apply {
            put("ack", packetIndex.toInt())
        }
        ConnectIQManager.sendMessage(
            device   = device,
            appId    = WATCH_APP_ID,
            message  = ackMsg,
            listener = object : ConnectIQ.IQSendMessageListener {
                override fun onMessageStatus(
                    d: IQDevice?,
                    a: IQApp?,
                    s: ConnectIQ.IQMessageStatus?
                ) {
                    if (s != ConnectIQ.IQMessageStatus.SUCCESS) {
                        // Log only — don't crash; watch will retransmit unACKed packets.
                        Log.w(TAG, "ACK send failed for pi=$packetIndex: ${s?.name}")
                    }
                }
            }
        )
    }

    private fun stopSession() {
        sessionManager.stopSession()
        fileLogger.flushAndClose()
        viewModel.updateSessionState(false)

        connectedDevice?.let { ConnectIQManager.unregisterForAppEvents(it, WATCH_APP_ID) }
        garminReceiver = null
        Log.i(TAG, "Session stopped")
    }

    // ── Export ───────────────────────────────────────────────────────

    private fun exportJsonl() {
        val sessionId = sessionManager.getCurrentSessionId()
            ?: fileLogger.getAllSessionFiles().firstOrNull()?.nameWithoutExtension
            ?: run {
                Toast.makeText(this, "No session to export", Toast.LENGTH_SHORT).show()
                return
            }

        val uri = exportManager.exportJsonl(sessionId, fileLogger) ?: run {
            Toast.makeText(this, "No data to export", Toast.LENGTH_SHORT).show()
            return
        }
        exportManager.shareFile(uri, "application/json")
    }

    private fun exportZip() {
        val sessionId = sessionManager.getCurrentSessionId()
            ?: fileLogger.getAllSessionFiles().firstOrNull()?.nameWithoutExtension
            ?: run {
                Toast.makeText(this, "No session to export", Toast.LENGTH_SHORT).show()
                return
            }

        val uri = exportManager.exportZip(sessionId, fileLogger) ?: run {
            Toast.makeText(this, "Export failed", Toast.LENGTH_SHORT).show()
            return
        }
        exportManager.shareFile(uri, "application/zip")
    }

    // ── Connect IQ initialisation ────────────────────────────────────

    private fun initConnectIQ() {
        viewModel.updateSdkStatus("INITIALIZING")
        ConnectIQManager.initialize(
            context = applicationContext,
            sdkType = ConnectIQ.IQConnectType.WIRELESS,
            onReady = {
                runOnUiThread {
                    viewModel.updateSdkStatus("READY")
                    discoverDevices()
                }
            },
            onError = { msg ->
                runOnUiThread {
                    viewModel.updateSdkStatus("ERROR: $msg")
                    viewModel.onError(msg)
                }
            }
        )
    }

    private fun discoverDevices() {
        val devices = ConnectIQManager.getConnectedDevices()
        if (devices.isNotEmpty()) {
            val d = devices.first()
            connectedDevice = d
            viewModel.updateWatchStatus("CONNECTED", d.friendlyName ?: d.deviceIdentifier.toString())
        } else {
            viewModel.updateWatchStatus("NOT_CONNECTED")
        }

        devices.forEach { device ->
            ConnectIQManager.registerForDeviceEvents(device) { dev, status ->
                runOnUiThread {
                    when (status) {
                        IQDevice.IQDeviceStatus.CONNECTED -> {
                            connectedDevice = dev
                            viewModel.updateWatchStatus("CONNECTED", dev.friendlyName ?: "-")
                        }
                        IQDevice.IQDeviceStatus.NOT_CONNECTED -> {
                            viewModel.updateWatchStatus("DISCONNECTED")
                        }
                        else -> viewModel.updateWatchStatus(status.name)
                    }
                }
            }
        }
    }

    // ── Permissions ──────────────────────────────────────────────────

    private fun requestPermissionsIfNeeded() {
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!isGranted(Manifest.permission.BLUETOOTH_SCAN))
                needed.add(Manifest.permission.BLUETOOTH_SCAN)
            if (!isGranted(Manifest.permission.BLUETOOTH_CONNECT))
                needed.add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        if (needed.isEmpty()) initConnectIQ()
        else permissionLauncher.launch(needed.toTypedArray())
    }

    private fun isGranted(p: String): Boolean =
        ContextCompat.checkSelfPermission(this, p) == PackageManager.PERMISSION_GRANTED

    // ── Lifecycle ────────────────────────────────────────────────────

    override fun onDestroy() {
        super.onDestroy()
        if (viewModel.uiState.value.sessionActive) stopSession()
        ConnectIQManager.cleanup()
    }

    // ── Helpers ──────────────────────────────────────────────────────

    private fun formatBytes(bytes: Long): String = when {
        bytes < 1024L         -> "$bytes B"
        bytes < 1024L * 1024L -> "${"%.1f".format(bytes / 1024f)} KB"
        else                  -> "${"%.2f".format(bytes / 1024f / 1024f)} MB"
    }
}
