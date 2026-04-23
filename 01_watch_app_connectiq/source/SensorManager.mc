import Toybox.Sensor;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

//! Manages IMU sensor registration and data collection.
//! Reads: accelerometer (x,y,z), gyroscope (x,y,z), magnetometer (x,y,z), HR.
//!
//! Uses Sensor.registerSensorDataListener which delivers batched samples.
//! Accel and gyro run at PRIMARY_RATE_HZ; magnetometer runs at MAG_RATE_HZ
//! (typically lower). For each primary sample i we use mag sample at index
//! i / MAG_DOWNSAMPLE_RATIO.
//!
//! HYPOTHESIS H-001: Accelerometer at 100 Hz via Sensor.registerSensorDataListener
//! HYPOTHESIS H-013: Accelerometer values in milli-g
class SensorManager {

    //! Callback type: called with each extracted sample dictionary
    typedef SampleCallback as Method(sample as Dictionary) as Void;

    //! Maximum samples in internal buffer
    private const MAX_BUFFER_SIZE = 400;

    //! Primary sample rate (accel + gyro)
    private const PRIMARY_RATE_HZ = 100;

    //! Magnetometer sample rate — usually 25 Hz max on Garmin hardware
    private const MAG_RATE_HZ = 25;

    //! Ratio primary/mag — used to index mag values across primary samples
    private const MAG_DOWNSAMPLE_RATIO = 4;  // 100 / 25

    //! Callback to deliver samples to SessionManager
    private var _callback as SampleCallback;

    //! Circular buffer of raw samples
    private var _buffer as Array<Dictionary>;

    //! Timestamp of last received sample (for t-offset per sample)
    private var _lastSampleTime as Number;

    //! Counter for frequency measurement window
    private var _sampleCount as Number;

    //! Timestamp when frequency window started
    private var _freqWindowStart as Number;

    //! Measured actual frequency in Hz
    private var _measuredFrequency as Float;

    //! Whether the sensor is currently registered
    private var _isRegistered as Boolean;

    //! @param callback Function called with each new sample
    function initialize(callback as SampleCallback) {
        _callback         = callback;
        _buffer           = [] as Array<Dictionary>;
        _lastSampleTime   = 0;
        _sampleCount      = 0;
        _freqWindowStart  = System.getTimer();
        _measuredFrequency = PRIMARY_RATE_HZ.toFloat();
        _isRegistered     = false;
    }

    //! Register sensor listeners. Called when session starts.
    function register() as Void {
        if (_isRegistered) {
            return;
        }

        // Accel/gyro at PRIMARY_RATE_HZ (100 Hz), mag at MAG_RATE_HZ (25 Hz).
        // HR is polled separately via Sensor.getInfo() — batched HeartRateData
        // only exposes heartBeatIntervals (RR ms), not bpm.
        var options = {
            :period        => 1,  // 1 second batching
            :accelerometer => { :enabled => true, :sampleRate => PRIMARY_RATE_HZ },
            :gyroscope     => { :enabled => true, :sampleRate => PRIMARY_RATE_HZ },
            :magnetometer  => { :enabled => true, :sampleRate => MAG_RATE_HZ }
        };

        try {
            Sensor.registerSensorDataListener(method(:onSensorDataReceived), options);
            _isRegistered    = true;
            _sampleCount     = 0;
            _freqWindowStart = System.getTimer();
            System.println("SensorManager: registered (accel/gyro="
                + PRIMARY_RATE_HZ + "Hz, mag=" + MAG_RATE_HZ + "Hz)");
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: register failed: " + ex.getErrorMessage());
        }
    }

    //! Unregister sensor listeners. Called when session stops.
    function unregister() as Void {
        if (!_isRegistered) {
            return;
        }
        try {
            Sensor.unregisterSensorDataListener();
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: unregister failed: " + ex.getErrorMessage());
        }
        _isRegistered = false;
        _buffer = [] as Array<Dictionary>;
        System.println("SensorManager: unregistered");
    }

    //! Batched sensor callback — called by Connect IQ runtime with accumulated samples.
    //! @param data SensorData with arrays of accel/gyro/mag values.
    //! Note: HeartRateData only exposes heartBeatIntervals (RR in ms), not bpm —
    //! we poll Sensor.getInfo().heartRate once per batch for the current bpm.
    function onSensorDataReceived(data as Sensor.SensorData) as Void {
        // ── Extract batched axis arrays ────────────────────────────
        var accel = (data has :accelerometerData) ? data.accelerometerData : null;
        var gyro  = (data has :gyroscopeData) ? data.gyroscopeData : null;
        var mag   = (data has :magnetometerData) ? data.magnetometerData : null;

        // Point-in-time HR (bpm) snapshot — applied to all samples in this batch
        var hrNow = 0;
        var info = Sensor.getInfo();
        if (info != null && info has :heartRate && info.heartRate != null) {
            hrNow = info.heartRate as Number;
        }

        // Determine batch size from the primary sensor (accel)
        var batchSize = 0;
        if (accel != null && accel.x != null) {
            batchSize = accel.x.size();
        } else if (gyro != null && gyro.x != null) {
            batchSize = gyro.x.size();
        } else if (mag != null && mag.x != null) {
            batchSize = mag.x.size();
        }

        if (batchSize == 0) {
            return;
        }

        // Expected per-sample period in ms for the primary (accel/gyro) rate
        var periodMs = 1000 / PRIMARY_RATE_HZ;

        // ── Cache axis arrays (may be null if sensor disabled) ────
        var accX = (accel != null) ? accel.x : null;
        var accY = (accel != null) ? accel.y : null;
        var accZ = (accel != null) ? accel.z : null;
        var gyrX = (gyro  != null) ? gyro.x  : null;
        var gyrY = (gyro  != null) ? gyro.y  : null;
        var gyrZ = (gyro  != null) ? gyro.z  : null;
        var magX = (mag   != null) ? mag.x   : null;
        var magY = (mag   != null) ? mag.y   : null;
        var magZ = (mag   != null) ? mag.z   : null;

        // ── Iterate and emit one sample per primary (accel/gyro) index ─
        // Magnetometer is sampled at MAG_RATE_HZ (lower); we hold its value
        // constant across MAG_DOWNSAMPLE_RATIO primary samples.
        for (var i = 0; i < batchSize; i++) {
            var magI = i / MAG_DOWNSAMPLE_RATIO;

            var ax = _safeFloat(accX, i);
            var ay = _safeFloat(accY, i);
            var az = _safeFloat(accZ, i);

            var gx = _safeFloat(gyrX, i);
            var gy = _safeFloat(gyrY, i);
            var gz = _safeFloat(gyrZ, i);

            var mx = _safeFloat(magX, magI);
            var my = _safeFloat(magY, magI);
            var mz = _safeFloat(magZ, magI);

            var sample = {
                "t"  => periodMs,
                "ax" => ax, "ay" => ay, "az" => az,
                "gx" => gx, "gy" => gy, "gz" => gz,
                "mx" => mx, "my" => my, "mz" => mz,
                "hr" => hrNow
            };

            // Buffer management
            if (_buffer.size() >= MAX_BUFFER_SIZE) {
                _buffer = _buffer.slice(1, null);
            }
            _buffer.add(sample);

            _callback.invoke(sample);
        }

        _lastSampleTime = System.getTimer();

        // ── Frequency measurement (rolling 1-second window) ────────
        _sampleCount += batchSize;
        var elapsed = System.getTimer() - _freqWindowStart;
        if (elapsed >= 1000) {
            _measuredFrequency = _sampleCount.toFloat() / (elapsed / 1000.0f);
            _sampleCount       = 0;
            _freqWindowStart   = System.getTimer();
        }
    }

    //! Safely read a value from a batched axis array at index i.
    private function _safeFloat(arr as Array?, i as Number) as Float {
        if (arr == null || i >= arr.size() || arr[i] == null) {
            return 0.0f;
        }
        return arr[i].toFloat();
    }

    //! Get all samples currently in the buffer.
    function getSamples() as Array<Dictionary> {
        return _buffer.slice(0, null);
    }

    //! Clear entire buffer.
    function clearBuffer() as Void {
        _buffer = [] as Array<Dictionary>;
    }

    //! Get the measured actual frequency.
    function getMeasuredFrequency() as Float {
        return _measuredFrequency;
    }

    //! Get current buffer occupancy.
    function getBufferSize() as Number {
        return _buffer.size();
    }

    //! Check if the sensor is currently registered.
    function isRegistered() as Boolean {
        return _isRegistered;
    }

    //! Get the latest SpO2 (Pulse Ox) measurement along with its age in seconds.
    //!
    //! SpO2 on Garmin watches is NOT a continuous sensor — it's sampled
    //! on-demand (~30 s), or periodically if "All-day Pulse Ox" is enabled
    //! (typically one measurement per 15-60 min), or during sleep.
    //! This method reads the newest entry from SensorHistory, which is the
    //! most recent SpO2 value known to the watch regardless of when it was
    //! captured (possibly minutes or hours ago).
    //!
    //! @return Dictionary with:
    //!   "value" => Number (0-100) or null if no measurement ever
    //!   "ageS"  => Number (seconds since measurement) or null
    function getSpo2Snapshot() as Dictionary {
        var spo2 = null;
        var ageS = null;
        try {
            if (Toybox has :SensorHistory
                && Toybox.SensorHistory has :getOxygenSaturationHistory) {
                var iter = Toybox.SensorHistory.getOxygenSaturationHistory({
                    :period => 1,
                    :order  => Toybox.SensorHistory.ORDER_NEWEST_FIRST
                });
                if (iter != null) {
                    var sample = iter.next();
                    if (sample != null && sample.data != null) {
                        spo2 = sample.data.toNumber();
                        if (sample has :when && sample.when != null) {
                            var nowSec  = Time.now().value();
                            var thenSec = sample.when.value();
                            ageS = nowSec - thenSec;
                            if (ageS < 0) { ageS = 0; }
                        }
                    }
                }
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: SpO2 read failed: " + ex.getErrorMessage());
        }
        return { "value" => spo2, "ageS" => ageS };
    }
}
