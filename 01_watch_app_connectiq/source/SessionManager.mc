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
        _state        = STATE_IDLE;
        _sessionId    = "";
        _packetIndex  = 0;
        _errorCount   = 0;
        _eventMarks   = [] as Array<Number>;
        _initialized  = false;
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
    function startSession() as Void {
        if (_state != STATE_IDLE) {
            return;
        }

        _sessionId   = generateSessionId();
        _packetIndex = 0;
        _errorCount  = 0;
        _eventMarks  = [] as Array<Number>;

        (_sensorManager   as SensorManager).register();
        (_positionManager as PositionManager).enable();
        (_batchManager    as BatchManager).reset();

        _state = STATE_RECORDING;
        System.println("SessionManager: started session " + _sessionId);
    }

    //! Stop the current capture session gracefully.
    //! Flushes any pending batch, then transitions to IDLE.
    function stopSession() as Void {
        if (_state != STATE_RECORDING) {
            return;
        }

        _state = STATE_STOPPING;
        System.println("SessionManager: stopping session " + _sessionId);

        // Flush remaining samples
        (_batchManager as BatchManager).flush();

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

        // Get latest SpO2 snapshot (null if no measurement ever recorded)
        var spo2Value = null;
        var spo2AgeS  = null;
        if (_sensorManager != null) {
            var snap = (_sensorManager as SensorManager).getSpo2Snapshot();
            spo2Value = snap.get("value");
            spo2AgeS  = snap.get("ageS");
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
            gpsData,
            battery,
            spo2Value,
            spo2AgeS,
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
