import Toybox.Sensor;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.ActivityMonitor;
import Toybox.UserProfile;

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

    //! Last RR intervals captured from the batched HeartRateData
    private var _lastRrIntervals as Array<Number> or Null;

    //! @param callback Function called with each new sample
    function initialize(callback as SampleCallback) {
        _callback         = callback;
        _buffer           = [] as Array<Dictionary>;
        _lastSampleTime   = 0;
        _sampleCount      = 0;
        _freqWindowStart  = System.getTimer();
        _measuredFrequency = PRIMARY_RATE_HZ.toFloat();
        _isRegistered     = false;
        _lastRrIntervals   = null;
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

        // ── Save RR intervals for this batch (for HRV analysis) ───
        // HeartRateData.heartBeatIntervals is an Array<Number> of RR in ms.
        if (data has :heartRateData && data.heartRateData != null) {
            var hrd = data.heartRateData;
            if (hrd has :heartBeatIntervals && hrd.heartBeatIntervals != null) {
                _lastRrIntervals = hrd.heartBeatIntervals;
            } else {
                _lastRrIntervals = null;
            }
        } else {
            _lastRrIntervals = null;
        }

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

    //! Return RR intervals (ms) captured from the most recent sensor batch.
    //! Typically 1-3 values per 1-second batch. Null if HR data was unavailable.
    function getLastRrIntervals() as Array<Number> or Null {
        return _lastRrIntervals;
    }

    //! Poll real-time Sensor.Info values (pressure, altitude, temperature,
    //! cadence, power, heading). Returns a Dictionary with only the fields
    //! that are available at call time.
    function getLiveSensorInfo() as Dictionary {
        var info = Sensor.getInfo();
        var out = {} as Dictionary;
        if (info == null) { return out; }

        if (info has :pressure && info.pressure != null) {
            out.put("pres_pa", info.pressure.toNumber());
        }
        if (info has :altitude && info.altitude != null) {
            out.put("alt_baro_m", info.altitude.toFloat());
        }
        if (info has :temperature && info.temperature != null) {
            out.put("temp_c", info.temperature.toFloat());
        }
        if (info has :cadence && info.cadence != null) {
            out.put("cadence", info.cadence.toNumber());
        }
        if (info has :power && info.power != null) {
            out.put("power_w", info.power.toNumber());
        }
        if (info has :heading && info.heading != null) {
            out.put("heading_rad", info.heading.toFloat());
        }
        return out;
    }

    //! Poll ActivityMonitor fields that update slowly (minutes).
    //! Each (value, age) is returned when available.
    function getActivityMonitorInfo() as Dictionary {
        var ai = ActivityMonitor.getInfo();
        var out = {} as Dictionary;
        if (ai == null) { return out; }

        if (ai has :respirationRate && ai.respirationRate != null) {
            out.put("resp", ai.respirationRate.toNumber());
        }
        if (ai has :stressScore && ai.stressScore != null) {
            out.put("stress", ai.stressScore.toNumber());
        }
        if (ai has :bodyBatteryLevel && ai.bodyBatteryLevel != null) {
            out.put("body_batt", ai.bodyBatteryLevel.toNumber());
        }
        if (ai has :steps && ai.steps != null) {
            out.put("steps_day", ai.steps.toNumber());
        }
        if (ai has :distance && ai.distance != null) {
            // ActivityMonitor.Info.distance is in cm → convert to m
            out.put("dist_day_m", (ai.distance.toNumber() / 100).toNumber());
        }
        if (ai has :floorsClimbed && ai.floorsClimbed != null) {
            out.put("floors_day", ai.floorsClimbed.toNumber());
        }
        return out;
    }

    //! Fetch the user profile (static data set in watch settings).
    //! Useful for normalising HR/power/distance metrics.
    function getUserProfile() as Dictionary {
        var out = {} as Dictionary;
        try {
            var prof = UserProfile.getProfile();
            if (prof == null) { return out; }
            if (prof has :weight && prof.weight != null) {
                out.put("weight_g", prof.weight.toNumber());
            }
            if (prof has :height && prof.height != null) {
                out.put("height_cm", prof.height.toNumber());
            }
            if (prof has :birthYear && prof.birthYear != null) {
                out.put("birth_year", prof.birthYear.toNumber());
            }
            if (prof has :gender && prof.gender != null) {
                out.put("gender",
                    prof.gender == UserProfile.GENDER_FEMALE ? "F" : "M");
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: UserProfile read failed: " + ex.getErrorMessage());
        }
        return out;
    }

    //! Generic history reader — returns an Array of [ts_unix_s, value] pairs,
    //! newest first, capped at maxN entries.
    //! @param iter  A SensorHistoryIterator (may be null if permission/support missing)
    //! @param maxN  Max entries to return
    private function _readHistory(iter, maxN as Number) as Array {
        var out = [] as Array;
        if (iter == null) { return out; }
        try {
            var count = 0;
            while (count < maxN) {
                var s = iter.next();
                if (s == null) { break; }
                if (s.data == null) { count++; continue; }
                var tsS = 0;
                if (s has :when && s.when != null) {
                    tsS = s.when.value();
                }
                out.add([tsS, s.data]);
                count++;
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: history read failed: " + ex.getErrorMessage());
        }
        return out;
    }

    //! Get last N HR samples (bpm).
    function getHrHistory(maxN as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getHeartRateHistory)) { return []; }
        var iter = Toybox.SensorHistory.getHeartRateHistory({
            :period => 1,
            :order  => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN);
    }

    //! Get last N HRV samples (typically ms RMSSD).
    function getHrvHistory(maxN as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getHeartRateVariabilityHistory)) { return []; }
        var iter = Toybox.SensorHistory.getHeartRateVariabilityHistory({
            :period => 1,
            :order  => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN);
    }

    //! Get last N SpO2 samples (%).
    function getSpo2History(maxN as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getOxygenSaturationHistory)) { return []; }
        var iter = Toybox.SensorHistory.getOxygenSaturationHistory({
            :period => 1,
            :order  => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN);
    }

    //! Get last N stress samples (0-100).
    function getStressHistory(maxN as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getStressHistory)) { return []; }
        var iter = Toybox.SensorHistory.getStressHistory({
            :period => 1,
            :order  => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN);
    }

    //! Get last N pressure samples (Pa).
    function getPressureHistory(maxN as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getPressureHistory)) { return []; }
        var iter = Toybox.SensorHistory.getPressureHistory({
            :period => 1,
            :order  => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN);
    }

    //! Get last N temperature samples (°C).
    function getTemperatureHistory(maxN as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getTemperatureHistory)) { return []; }
        var iter = Toybox.SensorHistory.getTemperatureHistory({
            :period => 1,
            :order  => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN);
    }

    //! Get last N barometric elevation samples (m).
    function getElevationHistory(maxN as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getElevationHistory)) { return []; }
        var iter = Toybox.SensorHistory.getElevationHistory({
            :period => 1,
            :order  => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN);
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
