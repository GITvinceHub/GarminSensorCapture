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
    private var _callbackCount;        // DIAG — how many times CIQ has called us
    private var _samplesPushed;        // DIAG — total samples pushed into BatchManager

    function initialize(batchManager) {
        _batchManager = batchManager;
        _isRegistered = false;
        _lastHrBpm = 0;
        _sampleCounter = 0;
        _errorCount = 0;
        _callbackCount = 0;
        _samplesPushed = 0;
    }

    //! DIAG accessors — surfaced in MainView so we can see from the watch whether
    //! the sensor stream is firing.
    function getCallbackCount() { return _callbackCount; }
    function getSamplesPushed() { return _samplesPushed; }

    //! Register with the Sensor framework. Idempotent.
    //! Returns true on success.
    //!
    //! GIQ-020: all optional APIs are gated via `has :` — if the device/firmware
    //!          doesn't expose them, we fall back silently (fatal "Symbol Not
    //!          Found" avoided).
    //! GIQ-022: options dict includes ONLY valid keys per Sensors doc —
    //!          :accelerometer, :gyroscope, :magnetometer, :heartBeatIntervals.
    //!          HR (bpm) is NOT an option of registerSensorDataListener; it is
    //!          refreshed from Sensor.getInfo() by the dispatch Timer (see
    //!          refreshHrFromInfo below — respects INV-009 outside callback).
    //! GIQ-023: we log a warning if the requested rate exceeds getMaxSampleRate()
    //!          but still attempt registration (driver will cap to its own max).
    function register() {
        if (_isRegistered) {
            return true;
        }
        if (!(Toybox.Sensor has :registerSensorDataListener)) {
            System.println("SensorManager: Sensor.registerSensorDataListener not available on this device");
            _isRegistered = false;
            _errorCount += 1;
            return false;
        }
        try {
            // GIQ-023: check max sample rate when the API is available.
            if (Sensor has :getMaxSampleRate) {
                var maxRate = Sensor.getMaxSampleRate();
                if (maxRate != null && maxRate < IMU_RATE_HZ) {
                    System.println("SensorManager: WARN requested " + IMU_RATE_HZ
                        + " Hz but device max is " + maxRate + " Hz");
                }
            }

            // Enable HR in the standard sensor stream so Sensor.getInfo().heartRate
            // becomes live (used by refreshHrFromInfo below — outside the hot callback).
            //
            // NB: we do NOT overwrite the device's enabled-sensor list; we only ADD
            // heart rate. Calling setEnabledSensors with [HEARTRATE] only has been
            // observed to interfere with the standard sensor stream on some
            // fēnix 8 firmwares — removing this call. HR will still be available
            // via Sensor.getInfo() because the default sensor config includes it
            // when the Sensor permission is granted.

            // CRITICAL FIX: Magnetometer on fēnix 8 tops out at 25 Hz. Asking for
            // 100 Hz was making registerSensorDataListener throw silently on some
            // firmwares, so the whole sensor stream never started (= 0 packets).
            // We request 25 Hz for mag (the native rate) and keep 100 Hz for
            // accel/gyro. Down-decimation still runs in the callback just in case.
            Sensor.registerSensorDataListener(
                method(:onSensorDataReceived),
                {
                    :period => 1,                                                   // 1-second batches (~100 samples)
                    :accelerometer => { :enabled => true, :sampleRate => IMU_RATE_HZ },
                    :gyroscope     => { :enabled => true, :sampleRate => IMU_RATE_HZ },
                    :magnetometer  => { :enabled => true, :sampleRate => MAG_RATE_HZ }
                    // NB: no :heartRate key — not a valid option (GIQ-022). HR is
                    // pulled via Sensor.getInfo() in refreshHrFromInfo() from the Timer.
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
            if (Toybox.Sensor has :unregisterSensorDataListener) {
                Sensor.unregisterSensorDataListener();
            }
            if (Sensor has :setEnabledSensors) {
                Sensor.setEnabledSensors([]);
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: unregister err " + ex.getErrorMessage());
        }
        _isRegistered = false;
    }

    //! Defensive accessor for a typed sensor array — protects against:
    //!   - arr == null (sensor not delivering this axis on this firmware)
    //!   - i >= arr.size() (axes arriving with different lengths)
    //!   - arr[i] == null (transient)
    //! Returns 0 when the value is not available. This is what kept v1.0 alive.
    private function _safeVal(arr, i) {
        if (arr == null) { return 0; }
        if (i >= arr.size()) { return 0; }
        var v = arr[i];
        if (v == null) { return 0; }
        return v;
    }

    //! HOT PATH — INV-009 / NFR-004: must stay < 50 ms.
    //! Pure accumulation: unpack arrays, push to buffer. That's it.
    function onSensorDataReceived(data as Sensor.SensorData) as Void {
        try {
            _callbackCount += 1;
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

            if (ax == null) { return; }
            var n = ax.size();
            if (n == 0) { return; }

            // Period per sample in ms (10 ms at 100 Hz). Fixed per protocol v1.
            var period = 1000 / IMU_RATE_HZ;

            for (var i = 0; i < n; i += 1) {
                _sampleCounter += 1;
                // Mag 25 Hz decimation — emit non-zero mag 1 sample out of MAG_DECIM.
                // mx array length is ~ n/4 since we requested 25 Hz; use i/MAG_DECIM
                // as the mag index and guard with _safeVal.
                var magI = i / MAG_DECIM;
                var sample = {
                    "t"  => period,
                    "ax" => _safeVal(ax, i),
                    "ay" => _safeVal(ay, i),
                    "az" => _safeVal(az, i),
                    "gx" => _safeVal(gx, i),
                    "gy" => _safeVal(gy, i),
                    "gz" => _safeVal(gz, i),
                    "mx" => _safeVal(mx, magI),
                    "my" => _safeVal(my, magI),
                    "mz" => _safeVal(mz, magI),
                    "hr" => _lastHrBpm
                };
                _batchManager.push(sample);
                _samplesPushed += 1;
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
    //! GIQ-020: Sensor.getInfo() is a core API present on every CIQ device, no gate needed.
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
