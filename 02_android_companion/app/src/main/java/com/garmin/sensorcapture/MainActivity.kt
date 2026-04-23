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
import com.garmin.android.connectiq.IQDevice
import kotlinx.coroutines.launch

private const val TAG = "MainActivity"
private const val WATCH_APP_ID = "a3b4c5d6-e7f8-1234-abcd-ef0123456789"

/**
 * Main Activity for GarminSensorCapture Android companion app.
 *
 * Responsibilities:
 * - Initialize Connect IQ SDK
 * - Display SDK, watch, session, and data status
 * - Control session start/stop
 * - Trigger JSONL/ZIP export
 */
class MainActivity : AppCompatActivity() {

    // ── ViewModel ─────────────────────────────────────────────────────
    private val viewModel: MainViewModel by viewModels()

    // ── Sub-system objects ─────────────────────────────────────────────
    private lateinit var sessionManager: SessionManager
    private lateinit var fileLogger: FileLogger
    private lateinit var exportManager: ExportManager
    private var garminReceiver: GarminReceiver? = null

    // ── Connected device ───────────────────────────────────────────────
    private var connectedDevice: IQDevice? = null

    // ── UI references ──────────────────────────────────────────────────
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

    // ── Permission launcher ────────────────────────────────────────────
    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.values.all { it }
        if (allGranted) {
            initConnectIQ()
        } else {
            Toast.makeText(this, "Bluetooth permissions required", Toast.LENGTH_LONG).show()
            Log.w(TAG, "Permissions not granted: $permissions")
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
        tvSdkStatus   = findViewById(R.id.tvSdkStatus)
        tvWatchStatus = findViewById(R.id.tvWatchStatus)
        tvWatchId     = findViewById(R.id.tvWatchId)
        tvPackets     = findViewById(R.id.tvPackets)
        tvFileSize    = findViewById(R.id.tvFileSize)
        tvThroughput  = findViewById(R.id.tvThroughput)
        tvError       = findViewById(R.id.tvError)
        tvSessionId   = findViewById(R.id.tvSessionId)
        tvLoss        = findViewById(R.id.tvLoss)
        btnStartStop  = findViewById(R.id.btnStartStop)
        btnExportJsonl = findViewById(R.id.btnExportJsonl)
        btnExportZip  = findViewById(R.id.btnExportZip)
        scrollView    = findViewById(R.id.scrollView)
    }

    private fun setupManagers() {
        sessionManager = SessionManager()
        fileLogger     = FileLogger(applicationContext)
        exportManager  = ExportManager(applicationContext)
    }

    private fun setupButtons() {
        btnStartStop.setOnClickListener {
            if (viewModel.uiState.value.sessionActive) {
                stopSession()
            } else {
                startSession()
            }
        }

        btnExportJsonl.setOnClickListener { exportJsonl() }
        btnExportZip.setOnClickListener   { exportZip() }
    }

    private fun observeViewModel() {
        lifecycleScope.launch {
            viewModel.uiState.collect { state ->
                updateUi(state)
            }
        }
    }

    private fun updateUi(state: UiState) {
        tvSdkStatus.text    = "SDK: ${state.sdkStatus}"
        tvWatchStatus.text  = "Watch: ${state.watchStatus}"
        tvWatchId.text      = "ID: ${state.watchId}"
        tvPackets.text      = "Packets: ${state.packetsReceived}"
        tvFileSize.text     = "File: ${formatBytes(state.fileSizeBytes)}"
        tvThroughput.text   = "Throughput: ${"%.2f".format(state.throughputPps)} pkt/s"
        tvSessionId.text    = "Session: ${state.sessionId ?: "-"}"
        tvLoss.text         = "Loss: ${"%.1f".format(state.packetLossPercent)}% (${state.gapsDetected} gaps)"

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
        val device = connectedDevice
        if (device == null) {
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

        // Create receiver and register for events
        garminReceiver = GarminReceiver(
            fileLogger      = fileLogger,
            sessionManager  = sessionManager,
            onPacketReceived = { packet ->
                runOnUiThread {
                    viewModel.onPacketReceived(
                        packet    = packet,
                        fileSizeBytes   = fileLogger.getCurrentFileSize(),
                        lossPercent     = garminReceiver?.getPacketLossPercent() ?: 0f,
                        gaps            = garminReceiver?.gapsDetected ?: 0
                    )
                }
            },
            onError = { msg ->
                runOnUiThread { viewModel.onError(msg) }
            }
        )

        ConnectIQManager.registerForAppEvents(device, WATCH_APP_ID, garminReceiver!!)
        Log.i(TAG, "Session started: $sessionId")
    }

    private fun stopSession() {
        sessionManager.stopSession()
        fileLogger.flushAndClose()
        viewModel.updateSessionState(false)

        val device = connectedDevice
        if (device != null) {
            ConnectIQManager.unregisterForAppEvents(device, WATCH_APP_ID)
        }

        garminReceiver = null
        Log.i(TAG, "Session stopped")
    }

    // ── Export ────────────────────────────────────────────────────────

    private fun exportJsonl() {
        val sessionId = sessionManager.getCurrentSessionId()
            ?: sessionManager.generateSessionId()

        val uri = exportManager.exportJsonl(sessionId, fileLogger) ?: run {
            Toast.makeText(this, "No data to export", Toast.LENGTH_SHORT).show()
            return
        }

        exportManager.shareFile(uri, "application/json")
    }

    private fun exportZip() {
        val sessionId = sessionManager.getCurrentSessionId()
            ?: sessionManager.generateSessionId()

        val uri = exportManager.exportZip(sessionId, fileLogger) ?: run {
            Toast.makeText(this, "Export failed", Toast.LENGTH_SHORT).show()
            return
        }

        exportManager.shareFile(uri, "application/zip")
    }

    // ── Connect IQ initialization ─────────────────────────────────────

    private fun initConnectIQ() {
        viewModel.updateSdkStatus("INITIALIZING")

        ConnectIQManager.initialize(
            context   = applicationContext,
            sdkType   = ConnectIQ.IQConnectType.WIRELESS,
            onReady   = {
                runOnUiThread {
                    viewModel.updateSdkStatus("READY")
                    discoverDevices()
                }
            },
            onError   = { msg ->
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
            val device = devices.first()
            connectedDevice = device
            viewModel.updateWatchStatus("CONNECTED", device.friendlyName ?: device.deviceIdentifier.toString())
            Log.i(TAG, "Watch connected: ${device.friendlyName}")
        } else {
            viewModel.updateWatchStatus("NOT_CONNECTED")
            Log.w(TAG, "No connected Garmin devices")
        }

        // Monitor device status changes
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
                        else -> {
                            viewModel.updateWatchStatus(status.name)
                        }
                    }
                }
            }
        }
    }

    // ── Permission handling ───────────────────────────────────────────

    private fun requestPermissionsIfNeeded() {
        val needed = mutableListOf<String>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (!isGranted(Manifest.permission.BLUETOOTH_SCAN))
                needed.add(Manifest.permission.BLUETOOTH_SCAN)
            if (!isGranted(Manifest.permission.BLUETOOTH_CONNECT))
                needed.add(Manifest.permission.BLUETOOTH_CONNECT)
        }

        if (needed.isEmpty()) {
            initConnectIQ()
        } else {
            permissionLauncher.launch(needed.toTypedArray())
        }
    }

    private fun isGranted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    // ── Lifecycle ─────────────────────────────────────────────────────

    override fun onDestroy() {
        super.onDestroy()
        if (viewModel.uiState.value.sessionActive) {
            stopSession()
        }
        ConnectIQManager.cleanup()
        Log.d(TAG, "Destroyed")
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private fun formatBytes(bytes: Long): String = when {
        bytes < 1024L            -> "$bytes B"
        bytes < 1024L * 1024L   -> "${"%.1f".format(bytes / 1024f)} KB"
        else                     -> "${"%.2f".format(bytes / 1024f / 1024f)} MB"
    }
}
