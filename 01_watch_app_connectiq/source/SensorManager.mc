//! SensorManager.mc
//! IMU acquisition (accel + gyro at 100 Hz, magnetometer at 25 Hz) and HR cache.
//!
//! INV-009 (critical, fixes v2 crash):
//!   The onSensorDataReceived callback only pushes samples into BatchManager.
//!   NO serialization, NO Communications.transmit, NO SensorHistory.*,
//!   NO Application.Storage.setValue, NO getInfo()-style heavy calls.
//!
//! The mag 25 Hz sub-sampling is done by picking one mag sample every 4 IMU samples
//! (since CIQ delivers accel/gyro/mag together per Sensor.SensorData).
using Toybox.Sensor;
using Toybox.Lang;
using Toybox.System;
using Toybox.Math;

class SensorManager {

    public static const IMU_RATE_HZ = 100;   // FR-001, FR-002
    public static const MAG_RATE_HZ = 25;    // FR-003 (decimated from 100 Hz stream)
    public static const MAG_DECIM = 4;       // 100 / 25

    private var _batchManager;
    private var _isRegistered;
    private var _lastHrBpm;            // cached HR, refreshed from Sensor.SensorInfo stream
    private var _sampleCounter;        // used for mag decimation
    private var _errorCount;

    function initialize(batchManager) {
        _batchManager = batchManager;
        _isRegistered = false;
        _lastHrBpm = 0;
        _sampleCounter = 0;
        _errorCount = 0;
    }

    //! Register with the Sensor framework. Idempotent.
    //! Returns true on success.
    function register() {
        if (_isRegistered) {
            return true;
        }
        try {
            // Sensor.setEnabledSensors enables additional non-default sensors. HR and mag
            // are enabled via the options dict of registerSensorDataListener below; keeping
            // this empty call here for future extension without breaking the build.
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
            Sensor.registerSensorDataListener(
                method(:onSensorDataReceived),
                {
                    :period => 1,                       // 1-second batches (~100 samples)
                    :accelerometer => { :enabled => true,  :sampleRate => IMU_RATE_HZ },
                    :gyroscope     => { :enabled => true,  :sampleRate => IMU_RATE_HZ },
                    :magnetometer  => { :enabled => true,  :sampleRate => IMU_RATE_HZ },
                    :heartRate     => { :enabled => true }
                }
            );
            _isRegistered = true;
            System.println("SensorManager: registered at " + IMU_RATE_HZ + " Hz");
            return true;
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: register FAILED " + ex.getErrorMessage());
            _isRegistered = false;
            _errorCount += 1;
            return false;
        }
    }

    function unregister() {
        if (!_isRegistered) {
            return;
        }
        try {
            Sensor.unregisterSensorDataListener();
            Sensor.setEnabledSensors([]);
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: unregister err " + ex.getErrorMessage());
        }
        _isRegistered = false;
    }

    //! HOT PATH — INV-009 / NFR-004: must stay < 50 ms.
    //! Pure accumulation: unpack arrays, push to buffer, cache HR. That's it.
    function onSensorDataReceived(data as Sensor.SensorData) as Void {
        try {
            if (data == null) { return; }

            var accel = data.accelerometerData;
            var gyro  = data.gyroscopeData;
            var mag   = data.magnetometerData;
            // HeartRateData carries RR intervals only (heartBeatIntervals); bpm is refreshed
            // by SessionManager's dispatch Timer via Sensor.getInfo() (safe outside this callback).
            // We do NOT read Sensor.getInfo() here to respect INV-009 / NFR-004.

            if (accel == null || gyro == null) {
                return;
            }

            var ax = accel.x;
            var ay = accel.y;
            var az = accel.z;
            var gx = gyro.x;
            var gy = gyro.y;
            var gz = gyro.z;
            var mx = (mag != null) ? mag.x : null;
            var my = (mag != null) ? mag.y : null;
            var mz = (mag != null) ? mag.z : null;

            var n = ax.size();
            if (n == 0) { return; }

            // Period per sample in ms (10 ms at 100 Hz). Fixed per protocol v1.
            var period = 1000 / IMU_RATE_HZ;

            for (var i = 0; i < n; i += 1) {
                _sampleCounter += 1;
                // Mag 25 Hz decimation — emit non-zero mag 1 sample out of MAG_DECIM.
                var emitMag = ((_sampleCounter % MAG_DECIM) == 0) && (mx != null) && (i < mx.size());
                var sample = {
                    "t"  => period,
                    "ax" => ax[i],
                    "ay" => ay[i],
                    "az" => az[i],
                    "gx" => gx[i],
                    "gy" => gy[i],
                    "gz" => gz[i],
                    "mx" => emitMag ? mx[i] : 0,
                    "my" => emitMag ? my[i] : 0,
                    "mz" => emitMag ? mz[i] : 0,
                    "hr" => _lastHrBpm
                };
                _batchManager.push(sample);
            }
        } catch (ex instanceof Lang.Exception) {
            // NFR-012/013: never propagate to the runtime.
            System.println("SensorManager: onSensorDataReceived FATAL " + ex.getErrorMessage());
            _errorCount += 1;
        }
    }

    function getLastHrBpm() { return _lastHrBpm; }
    function isRegistered() { return _isRegistered; }
    function getErrorCount() { return _errorCount; }

    //! Safe-to-call-outside-callback helper used by SessionManager's dispatch Timer
    //! to refresh the HR bpm cache. Respects INV-009: never called from the sensor callback.
    function refreshHrFromInfo() {
        try {
            var info = Sensor.getInfo();
            if (info != null && info.heartRate != null && info.heartRate > 0) {
                _lastHrBpm = info.heartRate;
            }
        } catch (ex instanceof Lang.Exception) {
            // quiet — HR is optional
        }
    }
}
