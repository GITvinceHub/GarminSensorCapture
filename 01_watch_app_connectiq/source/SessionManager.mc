import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! Manages the lifecycle of a sensor capture session.
//! State machine: IDLE → RECORDING → STOPPING → IDLE
//!
//! Owns references to SensorManager, PositionManager, BatchManager,
//! PacketSerializer, and CommunicationManager.
class SessionManager {

    //! Session state constants
    static const STATE_IDLE      = 0;
    static const STATE_RECORDING = 1;
    static const STATE_STOPPING  = 2;

    //! Current state
    private var _state as Number;

    //! Current session ID string
    private var _sessionId as String;

    //! Packet index counter (monotonic, resets each session)
    private var _packetIndex as Number;

    //! Total error count for this session
    private var _errorCount as Number;

    //! Unix timestamp (seconds) when the current session started.
    //! Used to filter in-session history entries for the footer packet.
    private var _sessionStartTsS as Number;

    //! System.getTimer() value at session start — used for elapsed-time display.
    private var _sessionStartTimerMs as Number;

    //! Event marks list (timestamps of marked events)
    private var _eventMarks as Array<Number>;

    //! Sub-system managers
    private var _sensorManager    as SensorManager or Null;
    private var _positionManager  as PositionManager or Null;
    private var _batchManager     as BatchManager or Null;
    private var _commManager      as CommunicationManager or Null;

    //! Persistent ACK-tracked queue (survives app restarts)
    private var _persistentQueue  as PersistentQueue or Null;

    //! Whether the session has been initialized (subsystems created)
    private var _initialized as Boolean;

    //! Battery level (0-100) at the moment the current session started.
    //! Used by ViewModel.computePowerQuality() to compute consumption rate.
    private var _sessionStartBattery as Number;

    //! Cached meta data — refreshed at most once per META_CACHE_TTL_MS.
    //! Avoids calling getSpo2Snapshot / getLiveSensorInfo / getActivityMonitorInfo
    //! 4 times per sensor callback (once per batch dispatch), which causes
    //! watchdog timeouts on fēnix 8 when those calls access flash/sensors.
    private var _cachedSpo2    as Dictionary;
    private var _cachedLive    as Dictionary;
    private var _cachedAmi     as Dictionary;
    private var _metaCacheTime as Number;
    private const META_CACHE_TTL_MS = 1000;  // refresh at most 1× per second

    //! Constructor — does NOT start capturing; call initialize() first
    function initialize() {
        _state                = STATE_IDLE;
        _sessionId            = "";
        _packetIndex          = 0;
        _errorCount           = 0;
        _eventMarks           = [] as Array<Number>;
        _sessionStartTsS      = 0;
        _sessionStartTimerMs  = 0;
        _sessionStartBattery  = 100;
        _initialized          = false;
        _sensorManager    = null;
        _positionManager  = null;
        _batchManager     = null;
        _commManager      = null;
        _persistentQueue  = null;
        _cachedSpo2    = {} as Dictionary;
        _cachedLive    = {} as Dictionary;
        _cachedAmi     = {} as Dictionary;
        _metaCacheTime = -META_CACHE_TTL_MS;  // force refresh on first batch
    }

    //! Initialize all sub-system managers.
    //! Called from GarminSensorApp.onStart().
    function setup() as Void {
        if (_initialized) {
            return;
        }

        _sensorManager   = new SensorManager(method(:onSensorSample));
        _positionManager = new PositionManager(method(:onGpsUpdate));
        _batchManager    = new BatchManager(method(:onBatchReady));
        _commManager     = new CommunicationManager(method(:onCommStatusChange));

        // ── Persistent queue: load any unACK-ed packets from previous run ──
        _persistentQueue = new PersistentQueue();
        (_commManager as CommunicationManager).setPersistentQueue(
            _persistentQueue as PersistentQueue);

        _commManager.openChannel();
        _initialized = true;
    }

    //! Cleanup all sub-systems.
    //! Called from GarminSensorApp.onStop().
    function cleanup() as Void {
        if (_state == STATE_RECORDING) {
            stopSession();
        }
        // Force-flush persistent queue so any in-memory dirty entries survive
        if (_persistentQueue != null) {
            (_persistentQueue as PersistentQueue).flush();
        }
        if (_sensorManager != null) {
            (_sensorManager as SensorManager).unregister();
        }
        if (_positionManager != null) {
            (_positionManager as PositionManager).disable();
        }
        if (_commManager != null) {
            (_commManager as CommunicationManager).closeChannel();
        }
        _initialized = false;
    }

    //! Start a new capture session.
    //! Generates a session ID and activates all sensors.
    //! Also builds and sends a session header packet containing user profile,
    //! device info and (capped) sensor histories.
    function startSession() as Void {
        if (_state != STATE_IDLE) {
            return;
        }

        _sessionId            = generateSessionId();
        _packetIndex          = 0;
        _errorCount           = 0;
        _eventMarks           = [] as Array<Number>;
        _sessionStartTsS      = Time.now().value();
        _sessionStartTimerMs  = System.getTimer();
        _sessionStartBattery  = System.getSystemStats().battery.toNumber();

        // ── Clear persistent queue: new session → fresh ACK cycle ──
        // Any packets from the previous session that were not ACK-ed are
        // discarded here.  Android should ACK the tail of the previous
        // session before the user starts a new one; if it has not, those
        // packets are considered unrecoverable.
        if (_persistentQueue != null) {
            (_persistentQueue as PersistentQueue).clear();
        }

        // ── Build and send the session header packet FIRST ─────────
        // Wrapped in its own try/catch — failure is non-fatal; the
        // data stream still starts even if the header is lost.
        try {
            _sendHeaderPacket();
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: header packet exception: " + ex.getErrorMessage());
            _errorCount++;
        }

        (_sensorManager   as SensorManager).register();
        (_positionManager as PositionManager).enable();
        (_batchManager    as BatchManager).reset();

        _state = STATE_RECORDING;
        System.println("SessionManager: started session " + _sessionId);
    }

    //! Build and transmit the session header packet (pt:"header") with user
    //! profile, device info and sensor histories. Errors are ignored (the
    //! main data stream proceeds either way).
    private function _sendHeaderPacket() as Void {
        if (_sensorManager == null || _commManager == null) { return; }

        // Max history entries per type — tuned to keep the header within
        // MAX_PACKET_SIZE when aggregated across 7 history streams.
        var MAX_HIST = 60;

        var sm = _sensorManager as SensorManager;

        var userProfile = sm.getUserProfile();

        var deviceInfo = {} as Dictionary;
        // Device info from System.getDeviceSettings / System.getSystemStats
        var devSettings = System.getDeviceSettings();
        if (devSettings != null) {
            if (devSettings has :partNumber && devSettings.partNumber != null) {
                deviceInfo.put("part_number", devSettings.partNumber);
            }
            if (devSettings has :firmwareVersion && devSettings.firmwareVersion != null) {
                deviceInfo.put("firmware", devSettings.firmwareVersion.toString());
            }
            if (devSettings has :monkeyVersion && devSettings.monkeyVersion != null) {
                deviceInfo.put("monkey_version", devSettings.monkeyVersion.toString());
            }
        }
        deviceInfo.put("app_version", "1.2.0");

        // Header histories = pre-session context (no cutoff → pass 0 for minTsS)
        var histories = {
            "hr"       => sm.getHrHistory(MAX_HIST, 0),
            "hrv"      => sm.getHrvHistory(MAX_HIST, 0),
            "spo2"     => sm.getSpo2History(MAX_HIST, 0),
            "stress"   => sm.getStressHistory(MAX_HIST, 0),
            "pressure" => sm.getPressureHistory(MAX_HIST, 0),
            "temp"     => sm.getTemperatureHistory(MAX_HIST, 0),
            "elev"     => sm.getElevationHistory(MAX_HIST, 0)
        } as Dictionary;

        var header = PacketSerializer.serializeHeaderPacket(
            _sessionId, System.getTimer(),
            userProfile, deviceInfo, histories
        );

        if (header != null) {
            (_commManager as CommunicationManager).sendPacket(header);
            System.println("SessionManager: header packet queued ("
                + header.length() + " chars)");
        }
    }

    //! Build and transmit the session footer packet (pt:"footer") with sensor
    //! histories captured during the session (ts >= _sessionStartTsS).
    //! Called from stopSession() before sensors are unregistered.
    private function _sendFooterPacket() as Void {
        if (_sensorManager == null || _commManager == null) { return; }
        if (_sessionStartTsS <= 0) { return; }

        // Higher cap than header since we want all in-session samples. The
        // per-type serializer truncates if the aggregate overflows MAX_PACKET_SIZE.
        var MAX_HIST = 200;

        var sm = _sensorManager as SensorManager;

        var histories = {
            "hr"       => sm.getHrHistory(MAX_HIST, _sessionStartTsS),
            "hrv"      => sm.getHrvHistory(MAX_HIST, _sessionStartTsS),
            "spo2"     => sm.getSpo2History(MAX_HIST, _sessionStartTsS),
            "stress"   => sm.getStressHistory(MAX_HIST, _sessionStartTsS),
            "pressure" => sm.getPressureHistory(MAX_HIST, _sessionStartTsS),
            "temp"     => sm.getTemperatureHistory(MAX_HIST, _sessionStartTsS),
            "elev"     => sm.getElevationHistory(MAX_HIST, _sessionStartTsS)
        } as Dictionary;

        var footer = PacketSerializer.serializeFooterPacket(
            _sessionId, _packetIndex, System.getTimer(), histories
        );

        if (footer != null) {
            (_commManager as CommunicationManager).sendPacket(footer);
            System.println("SessionManager: footer packet queued ("
                + footer.length() + " chars)");
        }
    }

    //! Stop the current capture session gracefully.
    //! Flushes any pending batch, then transitions to IDLE.
    function stopSession() as Void {
        if (_state != STATE_RECORDING) {
            return;
        }

        _state = STATE_STOPPING;
        System.println("SessionManager: stopping session " + _sessionId);

        // Flush remaining samples FIRST (may trigger one more data packet)
        (_batchManager as BatchManager).flush();

        // Send footer packet with in-session histories (before unregistering
        // sensors so the comm channel is still active)
        _sendFooterPacket();

        // Flush persistent queue to flash so no dirty entries are lost
        if (_persistentQueue != null) {
            (_persistentQueue as PersistentQueue).flush();
            System.println("SessionManager: persistent queue flushed ("
                + (_persistentQueue as PersistentQueue).size().toString()
                + " packets awaiting ACK)");
        }

        // Unregister sensors
        (_sensorManager   as SensorManager).unregister();
        (_positionManager as PositionManager).disable();

        _state = STATE_IDLE;
        System.println("SessionManager: session stopped. Packets sent: " + _packetIndex);
    }

    //! Mark a session event (lap, waypoint).
    function markEvent() as Void {
        if (_state == STATE_RECORDING) {
            _eventMarks.add(System.getTimer());
            System.println("SessionManager: event marked at " + System.getTimer());
        }
    }

    //! Generate a session ID from current wall-clock time.
    //! Format: "YYYYMMDD_HHMMSS"
    //! @return Session ID string
    function generateSessionId() as String {
        var now = Time.now();
        var info = Gregorian.info(now, Time.FORMAT_SHORT);

        var year  = info.year.format("%04d");
        var month = info.month.format("%02d");
        var day   = info.day.format("%02d");
        var hour  = info.hour.format("%02d");
        var min   = info.min.format("%02d");
        var sec   = info.sec.format("%02d");

        return year + month + day + "_" + hour + min + sec;
    }

    //! Get current session state.
    //! @return One of STATE_IDLE, STATE_RECORDING, STATE_STOPPING
    function getState() as Number {
        return _state;
    }

    //! Return a rich dictionary snapshot for UI display.
    //! Fields:
    //!   state, sessionId, elapsedMs, packetCount, errorCount, eventCount,
    //!   hasGpsFix, gpsQualityScore, isLinked, commQueueSize, commPersistentSize,
    //!   commSendFailures, imuFreqHz, lastHr, hasRrIntervals, batchesSent,
    //!   estimatedFileSizeBytes, droppedSamples, battery, sessionStartBattery
    function getStatus() as Dictionary {
        var hasGps          = false;
        var isLinked        = false;
        var gpsQ            = 0;
        var queueSz         = 0;
        var persistentSz    = 0;
        var sendFailures    = 0;
        var imuFreq         = 0.0f;
        var lastHr          = 0;
        var hasRr           = false;
        var batches         = 0;
        var droppedSamples  = 0;

        if (_positionManager != null) {
            var pm = _positionManager as PositionManager;
            hasGps = pm.hasValidFix();
            gpsQ   = pm.getQualityScore();
        }
        if (_commManager != null) {
            var cm = _commManager as CommunicationManager;
            isLinked     = cm.isConnected();
            queueSz      = cm.getQueueSize();
            sendFailures = cm.getSendFailures();
        }
        if (_persistentQueue != null) {
            persistentSz = (_persistentQueue as PersistentQueue).size();
        }
        if (_sensorManager != null) {
            var sm = _sensorManager as SensorManager;
            imuFreq = sm.getMeasuredFrequency();
            lastHr  = sm.getLastHrBpm();      // cached — no Sensor.getInfo() call
            hasRr   = sm.hasRrIntervals();
        }
        if (_batchManager != null) {
            var bm = _batchManager as BatchManager;
            batches       = bm.getBatchesSent();
            droppedSamples = bm.getDroppedSampleCount();
        }

        var elapsedMs = 0;
        if (_state == STATE_RECORDING || _state == STATE_STOPPING) {
            elapsedMs = System.getTimer() - _sessionStartTimerMs;
            if (elapsedMs < 0) { elapsedMs = 0; }
        }

        // Rough file-size estimate: 900 bytes per packet on average
        var fileSizeBytes = _packetIndex * 900;

        // Current battery level (0–100)
        var battery = System.getSystemStats().battery.toNumber();

        return {
            "state"                  => _state,
            "sessionId"              => _sessionId,
            "elapsedMs"              => elapsedMs,
            "packetCount"            => _packetIndex,
            "errorCount"             => _errorCount,
            "eventCount"             => _eventMarks.size(),
            "hasGpsFix"              => hasGps,
            "gpsQualityScore"        => gpsQ,
            "isLinked"               => isLinked,
            "commQueueSize"          => queueSz,
            "commPersistentSize"     => persistentSz,
            "commSendFailures"       => sendFailures,
            "imuFreqHz"              => imuFreq,
            "lastHr"                 => lastHr,
            "hasRrIntervals"         => hasRr,
            "batchesSent"            => batches,
            "estimatedFileSizeBytes" => fileSizeBytes,
            "droppedSamples"         => droppedSamples,
            "battery"                => battery,
            "sessionStartBattery"    => _sessionStartBattery
        };
    }

    //! Stop any ongoing session and immediately start a new one.
    //! Used for the START long-press "new file" action.
    function restartNewSession() as Void {
        if (_state == STATE_RECORDING) {
            stopSession();
        }
        if (_state == STATE_IDLE) {
            startSession();
        }
    }

    // ── Sub-manager accessors for UI layers ───────────────────────

    //! @return SensorManager instance, or null if not yet initialised
    function getSensorManager() as SensorManager or Null {
        return _sensorManager;
    }

    //! @return PositionManager instance, or null if not yet initialised
    function getPositionManager() as PositionManager or Null {
        return _positionManager;
    }

    //! @return BatchManager instance, or null if not yet initialised
    function getBatchManager() as BatchManager or Null {
        return _batchManager;
    }

    //! @return CommunicationManager instance, or null if not yet initialised
    function getCommManager() as CommunicationManager or Null {
        return _commManager;
    }

    //! Callback: called by SensorManager when a new IMU sample is ready.
    //! @param sample Dictionary with sensor values
    function onSensorSample(sample as Dictionary) as Void {
        if (_state != STATE_RECORDING) {
            return;
        }
        (_batchManager as BatchManager).accumulate(sample);
    }

    //! Callback: called by PositionManager when a new GPS fix arrives.
    //! Just updates the stored fix; no action needed here.
    function onGpsUpdate(gpsData as Dictionary) as Void {
        // GPS data is read lazily from PositionManager when building a packet
    }

    //! Callback: called by BatchManager when a batch is ready to send.
    //! @param samples Array of sample dictionaries
    //!
    //! Wrapped in try/catch: an exception here propagates through BatchManager
    //! and SensorManager callbacks back to the CIQ runtime, which exits the app.
    function onBatchReady(samples as Array<Dictionary>) as Void {
        if (_state != STATE_RECORDING && _state != STATE_STOPPING) {
            return;
        }
        try {
            _onBatchReadyImpl(samples);
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: FATAL in onBatchReady: " + ex.getErrorMessage());
            _errorCount++;
        }
    }

    //! Internal implementation of onBatchReady — separated so the outer function
    //! can catch any exception without polluting the method with nested try/catch.
    private function _onBatchReadyImpl(samples as Array<Dictionary>) as Void {
        // Get GPS snapshot
        var gpsData = null;
        if (_positionManager != null) {
            gpsData = (_positionManager as PositionManager).getLastFix();
        }

        // Get battery level (cheap — no flash/sensor access)
        var battery = System.getSystemStats().battery.toNumber();

        // ── Refresh meta cache at most once per META_CACHE_TTL_MS ─────
        // getSpo2Snapshot(), getLiveSensorInfo(), getActivityMonitorInfo() each
        // access flash storage or sensor hardware.  Calling them 4 times per
        // sensor callback (once per 25-sample batch) exceeds the CIQ watchdog
        // budget on fēnix 8.  We cache the results and refresh once per second.
        var nowMs = System.getTimer();
        if ((nowMs - _metaCacheTime) >= META_CACHE_TTL_MS && _sensorManager != null) {
            var sm = _sensorManager as SensorManager;
            try { _cachedSpo2 = sm.getSpo2Snapshot(); }
            catch (ex instanceof Lang.Exception) { _cachedSpo2 = {} as Dictionary; }
            try { _cachedLive = sm.getLiveSensorInfo(); }
            catch (ex instanceof Lang.Exception) { _cachedLive = {} as Dictionary; }
            try { _cachedAmi  = sm.getActivityMonitorInfo(); }
            catch (ex instanceof Lang.Exception) { _cachedAmi  = {} as Dictionary; }
            _metaCacheTime = nowMs;
        }

        // ── Build meta dict from cache + fresh battery ─────────────
        var meta = { "bat" => battery } as Dictionary;

        var spo2Val = _cachedSpo2.get("value");
        if (spo2Val != null) {
            meta.put("spo2", spo2Val);
            var spo2Age = _cachedSpo2.get("ageS");
            if (spo2Age != null) { meta.put("spo2_age_s", spo2Age); }
        }

        var liveKeys = _cachedLive.keys() as Array;
        for (var i = 0; i < liveKeys.size(); i++) {
            var k = liveKeys[i] as String;
            meta.put(k, _cachedLive.get(k));
        }

        var amKeys = _cachedAmi.keys() as Array;
        for (var j = 0; j < amKeys.size(); j++) {
            var k2 = amKeys[j] as String;
            meta.put(k2, _cachedAmi.get(k2));
        }

        // ── RR intervals from the most recent sensor batch ─────────
        var rrIntervals = null;
        if (_sensorManager != null) {
            rrIntervals = (_sensorManager as SensorManager).getLastRrIntervals();
        }

        // ── Serialize packet ───────────────────────────────────────
        var errorFlags = 0;
        if (gpsData == null) {
            errorFlags |= PacketSerializer.EF_GPS_ERROR;
        }

        var json = PacketSerializer.serializePacket(
            _sessionId,
            _packetIndex,
            System.getTimer(),
            samples,
            rrIntervals,
            gpsData,
            meta,
            errorFlags
        );

        // ── Send via BLE + persist for ACK tracking ────────────────
        if (json != null && json.length() > 0) {
            // Push to persistent queue BEFORE transmit so the packet is
            // durable even if the app crashes mid-send.  Removed only when
            // Android replies with {"ack": _packetIndex}.
            if (_persistentQueue != null) {
                (_persistentQueue as PersistentQueue).push(_packetIndex, json as String);
            }
            (_commManager as CommunicationManager).sendPacket(json);
            _packetIndex++;
        } else {
            _errorCount++;
            System.println("SessionManager: packet serialization failed");
        }
    }

    //! Callback: called by CommunicationManager on link status changes.
    //! @param connected true if BLE link is active
    function onCommStatusChange(connected as Boolean) as Void {
        System.println("SessionManager: comm status = " + connected.toString());
        if (!connected) {
            _errorCount++;
        }
    }
}
