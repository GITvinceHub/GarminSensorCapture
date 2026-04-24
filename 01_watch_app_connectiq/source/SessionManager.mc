//! SessionManager.mc
//! FSM and orchestrator — owns all subsystems and the dispatch Timer.
//!
//! States: IDLE → RECORDING → STOPPING → IDLE.
//! The dispatch Timer ticks every 250 ms (FR-011b) and is the ONLY place where
//! packets are serialized and handed to CommunicationManager.
//!
//! This module does NOT call Communications.transmit directly and does NOT touch
//! sensors from inside the sensor callback — that keeps INV-008 and INV-009 clean.
using Toybox.Timer;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.Lang;
using Toybox.Communications;

class SessionManager {

    public static const STATE_IDLE      = 0;
    public static const STATE_RECORDING = 1;
    public static const STATE_STOPPING  = 2;

    public static const DISPATCH_PERIOD_MS = 250;   // FR-011b
    public static const BATCH_SIZE = 25;            // samples per data packet

    private var _state;
    private var _sessionId;
    private var _packetIndex;
    private var _sessionStartTimer;     // System.getTimer() at startSession

    //! Subsystems.
    private var _batchManager;
    private var _sensorManager;
    private var _positionManager;
    private var _commManager;

    //! Dispatch timer.
    private var _dispatchTimer;

    //! Cached values refreshed at most once per dispatch tick (NFR-004b budget).
    private var _cachedBattery;
    private var _cachedBatteryAtMs;

    //! Error & stats counters for the UI.
    private var _errorCount;
    private var _lastErrorMsg;

    function initialize() {
        _state = STATE_IDLE;
        _sessionId = "";
        _packetIndex = 0;
        _sessionStartTimer = 0;

        _batchManager = new BatchManager();
        _sensorManager = new SensorManager(_batchManager);
        _positionManager = new PositionManager();
        _commManager = new CommunicationManager();

        _dispatchTimer = new Timer.Timer();

        _cachedBattery = 0;
        _cachedBatteryAtMs = -10000;

        _errorCount = 0;
        _lastErrorMsg = "";

        // Listen for ACKs / commands from the phone.
        // GIQ-020: gated `has :` — avoid Symbol Not Found on trimmed firmwares.
        try {
            if (Toybox.Communications has :registerForPhoneAppMessages) {
                Communications.registerForPhoneAppMessages(method(:onPhoneAppMessage));
            } else {
                System.println("SessionManager: Communications.registerForPhoneAppMessages not available");
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: registerForPhoneAppMessages FAILED " + ex.getErrorMessage());
        }
    }

    //! FSM — start recording. Idempotent if already RECORDING.
    function startSession() {
        if (_state == STATE_RECORDING) { return; }
        try {
            _sessionId = _generateSessionId();
            _packetIndex = 0;
            _sessionStartTimer = System.getTimer();
            _batchManager.clear();

            var okSensor = _sensorManager.register();
            _positionManager.enable();   // GPS may fail silently, that's OK (ef flag later)

            _state = STATE_RECORDING;
            _dispatchTimer.start(method(:_onDispatchTick), DISPATCH_PERIOD_MS, true);

            System.println("SessionManager: START sid=" + _sessionId + " sensorOk=" + okSensor);
        } catch (ex instanceof Lang.Exception) {
            _errorCount += 1;
            _lastErrorMsg = ex.getErrorMessage();
            System.println("SessionManager: startSession FATAL " + _lastErrorMsg);
        }
    }

    function stopSession() {
        if (_state == STATE_IDLE) { return; }
        try {
            _state = STATE_STOPPING;
            // Try one last flush of whatever is in the buffer.
            _dispatchOnce();

            _dispatchTimer.stop();
            _sensorManager.unregister();
            _positionManager.disable();

            _state = STATE_IDLE;
            System.println("SessionManager: STOP sid=" + _sessionId + " pi=" + _packetIndex);
        } catch (ex instanceof Lang.Exception) {
            _errorCount += 1;
            _lastErrorMsg = ex.getErrorMessage();
            System.println("SessionManager: stopSession FATAL " + _lastErrorMsg);
            _state = STATE_IDLE;
        }
    }

    function toggleSession() {
        if (_state == STATE_IDLE) {
            startSession();
        } else {
            stopSession();
        }
    }

    //! Called on app shutdown.
    function shutdown() {
        try {
            if (_state != STATE_IDLE) {
                stopSession();
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: shutdown err " + ex.getErrorMessage());
        }
    }

    //! Dispatch Timer tick — runs on the main thread, NOT from the sensor callback.
    //! NFR-004b: must complete in < 200 ms.
    function _onDispatchTick() {
        try {
            _dispatchOnce();
        } catch (ex instanceof Lang.Exception) {
            _errorCount += 1;
            _lastErrorMsg = ex.getErrorMessage();
            System.println("SessionManager: _onDispatchTick FATAL " + _lastErrorMsg);
        }
    }

    function _dispatchOnce() {
        if (_state == STATE_IDLE) { return; }

        var samples = _batchManager.pop(BATCH_SIZE);
        if (samples.size() == 0) { return; }

        var now = System.getTimer();
        _sensorManager.refreshHrFromInfo();  // safe here — not in sensor callback
        var gps = _positionManager.getLastFix();

        // Build the meta dict. Battery read is cheap-ish — cache for 1 s anyway (NFR-004b).
        if (now - _cachedBatteryAtMs > 1000) {
            try {
                var stats = System.getSystemStats();
                _cachedBattery = (stats != null && stats.battery != null) ? stats.battery.toNumber() : 0;
            } catch (ex instanceof Lang.Exception) {
                _cachedBattery = 0;
            }
            _cachedBatteryAtMs = now;
        }
        var meta = { "bat" => _cachedBattery };

        var ef = 0;
        if (_batchManager.consumeOverflowCount() > 0) {
            ef |= PacketSerializer.EF_BUFFER_OVERFLOW;
        }
        if (gps == null) {
            ef |= PacketSerializer.EF_GPS_ERROR;
        }

        var json = PacketSerializer.serializePacket(
            _sessionId, _packetIndex, now, samples, null, gps, meta, ef
        );
        if (json == null) {
            _errorCount += 1;
            return;
        }

        _commManager.sendPacket(json);
        _packetIndex += 1;
    }

    //! Phone→watch messages (ACKs). Keep it try/catch (NFR-012).
    function onPhoneAppMessage(msg as Communications.PhoneAppMessage) as Void {
        try {
            if (msg == null || msg.data == null) { return; }
            // For v2.0.0-from-spec we don't use a persistent queue; ACKs are informational.
            if (msg.data instanceof Lang.Dictionary && (msg.data as Lang.Dictionary).hasKey("ack")) {
                // Nothing to do — kept here so the phone side can still talk to us.
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: onPhoneAppMessage FATAL " + ex.getErrorMessage());
        }
    }

    //! sid = YYYYMMDD_HHMMSS
    function _generateSessionId() {
        try {
            var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
            return Lang.format(
                "$1$$2$$3$_$4$$5$$6$",
                [ info.year.format("%04d"),
                  info.month.format("%02d"),
                  info.day.format("%02d"),
                  info.hour.format("%02d"),
                  info.min.format("%02d"),
                  info.sec.format("%02d") ]
            );
        } catch (ex instanceof Lang.Exception) {
            // Fallback: uptime-based id.
            return "sid_" + System.getTimer().toString();
        }
    }

    // ── Accessors used by MainView ────────────────────────────────────
    function getState()          { return _state; }
    function getSessionId()      { return _sessionId; }
    function getPacketIndex()    { return _packetIndex; }
    function getBufferSize()     { return _batchManager.size(); }
    function getQueueSize()      { return _commManager.getQueueSize(); }
    function getPacketsSent()    { return _commManager.getPacketsSent(); }
    function getPacketsFailed()  { return _commManager.getPacketsFailed(); }
    function isLinkUp()          { return _commManager.isLinkUp(); }
    function getLastHrBpm()      { return _sensorManager.getLastHrBpm(); }
    function getBattery()        { return _cachedBattery; }
    function hasGpsFix()         { return _positionManager.getLastFix() != null; }
    function getErrorCount()     { return _errorCount + _sensorManager.getErrorCount() + _positionManager.getErrorCount(); }
    function getLastError()      { return _lastErrorMsg; }
    function getElapsedSec() {
        if (_state == STATE_IDLE) { return 0; }
        return (System.getTimer() - _sessionStartTimer) / 1000;
    }
}
