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

    //! Event marks list (timestamps of marked events)
    private var _eventMarks as Array<Number>;

    //! Sub-system managers
    private var _sensorManager    as SensorManager or Null;
    private var _positionManager  as PositionManager or Null;
    private var _batchManager     as BatchManager or Null;
    private var _commManager      as CommunicationManager or Null;

    //! Whether the session has been initialized (subsystems created)
    private var _initialized as Boolean;

    //! Constructor — does NOT start capturing; call initialize() first
    function initialize() {
        _state           = STATE_IDLE;
        _sessionId       = "";
        _packetIndex     = 0;
        _errorCount      = 0;
        _eventMarks      = [] as Array<Number>;
        _sessionStartTsS = 0;
        _initialized     = false;
        _sensorManager   = null;
        _positionManager = null;
        _batchManager    = null;
        _commManager     = null;
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

        _commManager.openChannel();
        _initialized = true;
    }

    //! Cleanup all sub-systems.
    //! Called from GarminSensorApp.onStop().
    function cleanup() as Void {
        if (_state == STATE_RECORDING) {
            stopSession();
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

        _sessionId       = generateSessionId();
        _packetIndex     = 0;
        _errorCount      = 0;
        _eventMarks      = [] as Array<Number>;
        _sessionStartTsS = Time.now().value();

        // ── Build and send the session header packet FIRST ─────────
        _sendHeaderPacket();

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

    //! Return a dictionary snapshot of the current status for UI display.
    //! @return Dictionary with keys: state, packetCount, hasGpsFix, isLinked, errorCount
    function getStatus() as Dictionary {
        var hasGps  = false;
        var isLinked = false;

        if (_positionManager != null) {
            hasGps = (_positionManager as PositionManager).hasValidFix();
        }
        if (_commManager != null) {
            isLinked = (_commManager as CommunicationManager).isConnected();
        }

        return {
            "state"       => _state,
            "packetCount" => _packetIndex,
            "hasGpsFix"   => hasGps,
            "isLinked"    => isLinked,
            "errorCount"  => _errorCount
        };
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
    function onBatchReady(samples as Array<Dictionary>) as Void {
        if (_state != STATE_RECORDING && _state != STATE_STOPPING) {
            return;
        }

        // Get GPS snapshot
        var gpsData = null;
        if (_positionManager != null) {
            gpsData = (_positionManager as PositionManager).getLastFix();
        }

        // Get battery level
        var battery = System.getSystemStats().battery.toNumber();

        // ── Build comprehensive meta dict ──────────────────────────
        var meta = { "bat" => battery } as Dictionary;

        if (_sensorManager != null) {
            var sm = _sensorManager as SensorManager;

            // SpO2 (via SensorHistory)
            var snap = sm.getSpo2Snapshot();
            if (snap.get("value") != null) {
                meta.put("spo2", snap.get("value"));
                if (snap.get("ageS") != null) {
                    meta.put("spo2_age_s", snap.get("ageS"));
                }
            }

            // Live Sensor.Info polls (pressure, altitude, temp, cadence, power, heading)
            var live = sm.getLiveSensorInfo();
            var liveKeys = live.keys() as Array;
            for (var i = 0; i < liveKeys.size(); i++) {
                var k = liveKeys[i] as String;
                meta.put(k, live.get(k));
            }

            // ActivityMonitor polls (resp, stress, body_batt, steps, dist, floors)
            var ami = sm.getActivityMonitorInfo();
            var amKeys = ami.keys() as Array;
            for (var j = 0; j < amKeys.size(); j++) {
                var k2 = amKeys[j] as String;
                meta.put(k2, ami.get(k2));
            }
        }

        // RR intervals from the most recent sensor batch (HRV source)
        var rrIntervals = null;
        if (_sensorManager != null) {
            rrIntervals = (_sensorManager as SensorManager).getLastRrIntervals();
        }

        // Serialize packet
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

        // Send via BLE
        if (json != null && json.length() > 0) {
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
