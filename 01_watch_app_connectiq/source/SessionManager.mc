import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

//! Orchestrator — owns all sensor, batch, communication and persistent subsystems.
//!
//! Implements contracts C-050, C-051 per SPECIFICATION.md §7.6.
//! State machine: IDLE → RECORDING → STOPPING → IDLE (§6.2).
//!
//! INVARIANTS:
//!  - INV-001: _packetIndex monotone within a session.
//!  - INV-002: sessionId unique (YYYYMMDD_HHMMSS wall-clock).
//!  - INV-003: header is first packet (pi=0, pt="header").
//!  - INV-004: footer is last packet (pt="footer").
//!
//! Watchdog budget (NFR-004): the onBatchReady callback may fire 4×/s at 100 Hz
//! IMU. Expensive meta gathers (SpO2/ActivityMonitor/Sensor.getInfo) are cached
//! at most 1×/s via META_CACHE_TTL_MS to stay well inside the 400 ms budget.
class SessionManager {

    static const STATE_IDLE      = 0;
    static const STATE_RECORDING = 1;
    static const STATE_STOPPING  = 2;

    private var _state               as Number;
    private var _sessionId           as String;
    private var _packetIndex         as Number;
    private var _errorCount          as Number;
    private var _sessionStartTsS     as Number;
    private var _sessionStartTimerMs as Number;
    private var _eventMarks          as Array<Number>;
    private var _sessionStartBattery as Number;

    private var _sensorManager    as SensorManager    or Null;
    private var _positionManager  as PositionManager  or Null;
    private var _batchManager     as BatchManager     or Null;
    private var _commManager      as CommunicationManager or Null;
    private var _persistentQueue  as PersistentQueue  or Null;

    private var _initialized as Boolean;

    //! C-051 cache — refreshed at most 1× per META_CACHE_TTL_MS.
    private var _cachedSpo2    as Dictionary;
    private var _cachedLive    as Dictionary;
    private var _cachedAmi     as Dictionary;
    private var _metaCacheTime as Number;
    private const META_CACHE_TTL_MS = 1000;

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
        _sensorManager   = null;
        _positionManager = null;
        _batchManager    = null;
        _commManager     = null;
        _persistentQueue = null;
        _cachedSpo2    = {} as Dictionary;
        _cachedLive    = {} as Dictionary;
        _cachedAmi     = {} as Dictionary;
        _metaCacheTime = -META_CACHE_TTL_MS;
    }

    //! Wire all subsystems. Idempotent — called from GarminSensorApp.onStart().
    function setup() as Void {
        if (_initialized) { return; }

        _sensorManager   = new SensorManager(method(:onSensorSample));
        _positionManager = new PositionManager(method(:onGpsUpdate));
        _batchManager    = new BatchManager(method(:onBatchReady));
        _commManager     = new CommunicationManager(method(:onCommStatusChange));

        _persistentQueue = new PersistentQueue();
        (_commManager as CommunicationManager).setPersistentQueue(
            _persistentQueue as PersistentQueue);

        _commManager.openChannel();
        _initialized = true;
    }

    //! Tear everything down. Called from GarminSensorApp.onStop().
    function cleanup() as Void {
        if (_state == STATE_RECORDING) {
            stopSession();
        }
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

    //! C-050 startSession().
    //! Precondition: _state == STATE_IDLE.
    //! Postcondition (success): _state == STATE_RECORDING, _packetIndex == 0,
    //!   persistent queue cleared, header packet emitted (INV-003), sensors registered.
    function startSession() as Void {
        if (_state != STATE_IDLE) { return; }

        _sessionId            = generateSessionId();
        _packetIndex          = 0;
        _errorCount           = 0;
        _eventMarks           = [] as Array<Number>;
        _sessionStartTsS      = Time.now().value();
        _sessionStartTimerMs  = System.getTimer();
        _sessionStartBattery  = System.getSystemStats().battery.toNumber();
        _metaCacheTime        = -META_CACHE_TTL_MS;  // force first refresh

        // Clear persistent queue — new session means fresh pi counter.
        if (_persistentQueue != null) {
            (_persistentQueue as PersistentQueue).clear();
        }

        // Header packet first (INV-003). Isolated try/catch — header failure
        // is non-fatal; the data stream still starts.
        try {
            _sendHeaderPacket();
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: header packet failed: " + ex.getErrorMessage());
            _errorCount++;
        }

        // Each subsystem may fail independently; per C-050 "postcondition
        // (partial failure)" we still transition to RECORDING if at least
        // the IMU or GPS started.
        try {
            (_sensorManager as SensorManager).register();
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: sensor register failed: " + ex.getErrorMessage());
            _errorCount++;
        }
        try {
            (_positionManager as PositionManager).enable();
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: position enable failed: " + ex.getErrorMessage());
            _errorCount++;
        }
        try {
            (_batchManager as BatchManager).reset();
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: batch reset failed: " + ex.getErrorMessage());
            _errorCount++;
        }

        _state = STATE_RECORDING;
        System.println("SessionManager: started session " + _sessionId);
    }

    //! Send the session header packet (pt="header", pi=0) per §8.2.
    private function _sendHeaderPacket() as Void {
        if (_sensorManager == null || _commManager == null) { return; }

        var MAX_HIST = 60;  // per FR-008 + SPECIFICATION.md §8.2

        var sm = _sensorManager as SensorManager;

        var userProfile = sm.getUserProfile();

        var deviceInfo = {} as Dictionary;
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
        deviceInfo.put("app_version", "2.0.0");

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
            System.println("SessionManager: header queued (" + header.length().toString() + " chars)");
        }
    }

    //! Send the session footer packet (pt="footer") per §8.3. INV-004.
    private function _sendFooterPacket() as Void {
        if (_sensorManager == null || _commManager == null) { return; }
        if (_sessionStartTsS <= 0) { return; }

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
            System.println("SessionManager: footer queued (" + footer.length().toString() + " chars)");
        }
    }

    //! Gracefully stop the session: flush batch → emit footer → unregister.
    function stopSession() as Void {
        if (_state != STATE_RECORDING) { return; }

        _state = STATE_STOPPING;
        System.println("SessionManager: stopping session " + _sessionId);

        // Flush first — may trigger one final data packet.
        try {
            (_batchManager as BatchManager).flush();
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: batch flush failed: " + ex.getErrorMessage());
            _errorCount++;
        }

        // Footer (INV-004) — channel still active.
        try {
            _sendFooterPacket();
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: footer failed: " + ex.getErrorMessage());
            _errorCount++;
        }

        // Durable flush — any dirty entries in the queue survive a crash.
        if (_persistentQueue != null) {
            try {
                (_persistentQueue as PersistentQueue).flush();
                System.println("SessionManager: persistent queue flushed ("
                    + (_persistentQueue as PersistentQueue).size().toString()
                    + " packets awaiting ACK)");
            } catch (ex instanceof Lang.Exception) {
                System.println("SessionManager: pq flush failed: " + ex.getErrorMessage());
            }
        }

        try { (_sensorManager   as SensorManager).unregister();   } catch (ex instanceof Lang.Exception) { }
        try { (_positionManager as PositionManager).disable();    } catch (ex instanceof Lang.Exception) { }

        _state = STATE_IDLE;
        System.println("SessionManager: session stopped. Packets sent: " + _packetIndex.toString());
    }

    //! Mark a session event (lap / waypoint).
    function markEvent() as Void {
        if (_state == STATE_RECORDING) {
            _eventMarks.add(System.getTimer());
            System.println("SessionManager: event marked at " + System.getTimer().toString());
        }
    }

    //! INV-002 — session ID is the wall-clock "YYYYMMDD_HHMMSS".
    function generateSessionId() as String {
        var now  = Time.now();
        var info = Gregorian.info(now, Time.FORMAT_SHORT);
        return info.year.format("%04d")
             + info.month.format("%02d")
             + info.day.format("%02d")
             + "_"
             + info.hour.format("%02d")
             + info.min.format("%02d")
             + info.sec.format("%02d");
    }

    function getState() as Number { return _state; }

    //! Rich snapshot for UI rendering.
    function getStatus() as Dictionary {
        var hasGps         = false;
        var isLinked       = false;
        var gpsQ           = 0;
        var queueSz        = 0;
        var persistentSz   = 0;
        var sendFailures   = 0;
        var imuFreq        = 0.0f;
        var lastHr         = 0;
        var hasRr          = false;
        var batches        = 0;
        var droppedSamples = 0;

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
            lastHr  = sm.getLastHrBpm();
            hasRr   = sm.hasRrIntervals();
        }
        if (_batchManager != null) {
            var bm = _batchManager as BatchManager;
            batches        = bm.getBatchesSent();
            droppedSamples = bm.getDroppedSampleCount();
        }

        var elapsedMs = 0;
        if (_state == STATE_RECORDING || _state == STATE_STOPPING) {
            elapsedMs = System.getTimer() - _sessionStartTimerMs;
            if (elapsedMs < 0) { elapsedMs = 0; }
        }

        var fileSizeBytes = _packetIndex * 900;  // rough estimate
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

    //! Used by START long-press: stop any ongoing session, then start a new one.
    function restartNewSession() as Void {
        if (_state == STATE_RECORDING) { stopSession(); }
        if (_state == STATE_IDLE)      { startSession(); }
    }

    // Accessors for UI layers
    function getSensorManager()   as SensorManager or Null      { return _sensorManager;   }
    function getPositionManager() as PositionManager or Null    { return _positionManager; }
    function getBatchManager()    as BatchManager or Null       { return _batchManager;    }
    function getCommManager()     as CommunicationManager or Null { return _commManager;   }

    //! Sensor callback — sample arrived from IMU.
    function onSensorSample(sample as Dictionary) as Void {
        if (_state != STATE_RECORDING) { return; }
        try {
            (_batchManager as BatchManager).accumulate(sample);
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: accumulate failed: " + ex.getErrorMessage());
            _errorCount++;
        }
    }

    //! GPS callback — data is lazily pulled from PositionManager at batch time.
    function onGpsUpdate(gpsData as Dictionary) as Void {
        // No-op — GPS is sampled lazily in _onBatchReadyImpl.
    }

    //! C-051 onBatchReady(samples).
    //! Precondition: samples.size() > 0.
    //! Postcondition: if state ∈ {RECORDING, STOPPING}, packet serialised,
    //!   pushed to persistent queue, transmitted; _packetIndex incremented.
    //!   NFR-012: no exception propagates.
    function onBatchReady(samples as Array<Dictionary>) as Void {
        if (_state != STATE_RECORDING && _state != STATE_STOPPING) { return; }
        try {
            _onBatchReadyImpl(samples);
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: FATAL in onBatchReady: " + ex.getErrorMessage());
            _errorCount++;
        }
    }

    private function _onBatchReadyImpl(samples as Array<Dictionary>) as Void {
        var gpsData = null;
        if (_positionManager != null) {
            gpsData = (_positionManager as PositionManager).getLastFix();
        }

        var battery = System.getSystemStats().battery.toNumber();

        // Meta cache refresh (NFR-004 watchdog budget) — once per second.
        var nowMs = System.getTimer();
        if ((nowMs - _metaCacheTime) >= META_CACHE_TTL_MS && _sensorManager != null) {
            var sm = _sensorManager as SensorManager;
            try { _cachedSpo2 = sm.getSpo2Snapshot(); }
            catch (ex instanceof Lang.Exception) { _cachedSpo2 = {} as Dictionary; }
            try { _cachedLive = sm.getLiveSensorInfo(); }
            catch (ex instanceof Lang.Exception) { _cachedLive = {} as Dictionary; }
            try { _cachedAmi = sm.getActivityMonitorInfo(); }
            catch (ex instanceof Lang.Exception) { _cachedAmi = {} as Dictionary; }
            _metaCacheTime = nowMs;
        }

        // Build meta dict from cache + fresh battery.
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

        var rrIntervals = null;
        if (_sensorManager != null) {
            rrIntervals = (_sensorManager as SensorManager).getLastRrIntervals();
        }

        var errorFlags = 0;
        if (gpsData == null) { errorFlags |= PacketSerializer.EF_GPS_ERROR; }

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

        if (json != null && json.length() > 0) {
            // Push persistent BEFORE transmit so a crash mid-send doesn't lose data.
            if (_persistentQueue != null) {
                (_persistentQueue as PersistentQueue).push(_packetIndex, json as String);
            }
            (_commManager as CommunicationManager).sendPacket(json);
            _packetIndex++;  // INV-001: monotone increment.
        } else {
            _errorCount++;
            System.println("SessionManager: packet serialization failed");
        }
    }

    //! Called by CommunicationManager on link state changes.
    function onCommStatusChange(connected as Boolean) as Void {
        try {
            System.println("SessionManager: comm status = " + connected.toString());
            if (!connected) { _errorCount++; }
        } catch (ex instanceof Lang.Exception) {
            System.println("SessionManager: onCommStatusChange failed: " + ex.getErrorMessage());
        }
    }
}
