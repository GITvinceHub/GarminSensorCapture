import Toybox.Sensor;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.ActivityMonitor;
import Toybox.UserProfile;
import Toybox.Math;

//! Sensor subsystem — IMU (accel/gyro @ 100 Hz) + magnetometer (25 Hz) + HR.
//!
//! Implements contracts C-001..C-003 per SPECIFICATION.md §7.1.
//! Targets FR-001 (accel 100 Hz), FR-002 (gyro 100 Hz), FR-003 (mag 25 Hz),
//!         FR-004 (HR), FR-005 (RR intervals), FR-007 (live sensor meta),
//!         FR-008 (history arrays for header/footer).
//!
//! INVARIANTS:
//!  - _buffer.size() <= MAX_BUFFER_SIZE (50) at all times.
//!  - No exception propagates from onSensorDataReceived (NFR-012).
class SensorManager {

    //! Callback type: called with each extracted sample dictionary.
    typedef SampleCallback as Method(sample as Dictionary) as Void;

    //! Maximum samples in internal circular buffer.
    //! Kept at 50: only used for UI sparklines (last ~0.5 s). A larger buffer
    //! triggers repeated Array.slice() allocations on every sample once full
    //! and floods the GC on memory-limited CIQ runtimes.
    private const MAX_BUFFER_SIZE = 50;

    //! Primary sample rate (accel + gyro) in Hz — FR-001, FR-002.
    private const PRIMARY_RATE_HZ = 100;

    //! Magnetometer sample rate in Hz — FR-003 (25 Hz, sous-échantillonné).
    private const MAG_RATE_HZ = 25;

    //! Ratio primary / mag — used to index mag values across primary samples.
    private const MAG_DOWNSAMPLE_RATIO = 4;  // 100 / 25

    private var _callback as SampleCallback;
    private var _buffer as Array<Dictionary>;
    private var _sampleCount as Number;
    private var _freqWindowStart as Number;
    private var _measuredFrequency as Float;
    private var _isRegistered as Boolean;
    private var _lastRrIntervals as Array<Number> or Null;
    private var _lastHrBpm as Number;

    //! @param callback Function invoked with each new sample (C-001 postcondition).
    function initialize(callback as SampleCallback) {
        _callback          = callback;
        _buffer            = [] as Array<Dictionary>;
        _sampleCount       = 0;
        _freqWindowStart   = System.getTimer();
        _measuredFrequency = PRIMARY_RATE_HZ.toFloat();
        _isRegistered      = false;
        _lastRrIntervals   = null;
        _lastHrBpm         = 0;
    }

    //! C-001 register() — precondition: _isRegistered == false.
    //! Postcondition (success): _isRegistered == true AND callback fires ~1×/s.
    //! Postcondition (failure): _isRegistered == false AND error logged.
    function register() as Void {
        if (_isRegistered) { return; }

        var options = {
            :period        => 1,  // seconds of batching
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
                + PRIMARY_RATE_HZ.toString() + "Hz, mag="
                + MAG_RATE_HZ.toString() + "Hz)");
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: register failed: " + ex.getErrorMessage());
            _isRegistered = false;
        }
    }

    //! Unregister sensor listeners. Safe to call when not registered.
    function unregister() as Void {
        if (!_isRegistered) { return; }
        try {
            Sensor.unregisterSensorDataListener();
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: unregister failed: " + ex.getErrorMessage());
        }
        _isRegistered = false;
        _buffer = [] as Array<Dictionary>;
        System.println("SensorManager: unregistered");
    }

    //! C-002 onSensorDataReceived(data) — CIQ runtime callback.
    //! WRAPPED IN TRY/CATCH per NFR-012: no exception propagates to CIQ.
    //! Precondition: data is a Sensor.SensorData (may be malformed).
    //! Postcondition: each extracted sample delivered via _callback.invoke();
    //!   _buffer holds at most MAX_BUFFER_SIZE latest samples;
    //!   _measuredFrequency updated approximately once per second.
    function onSensorDataReceived(data as Sensor.SensorData) as Void {
        try {
            _onSensorDataReceivedImpl(data);
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: FATAL in callback: " + ex.getErrorMessage());
            // Swallow — NFR-013.
        }
    }

    private function _onSensorDataReceivedImpl(data as Sensor.SensorData) as Void {
        if (data == null) { return; }

        // Extract batched axis arrays — any may be null on sensor failure.
        var accel = (data has :accelerometerData) ? data.accelerometerData : null;
        var gyro  = (data has :gyroscopeData)     ? data.gyroscopeData     : null;
        var mag   = (data has :magnetometerData)  ? data.magnetometerData  : null;

        // RR intervals (HRV source, FR-005) — Array<Number> of RR in ms.
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

        // Point-in-time HR snapshot (applied uniformly across batch).
        var hrNow = 0;
        var info = Sensor.getInfo();
        if (info != null && info has :heartRate && info.heartRate != null) {
            hrNow = info.heartRate as Number;
        }
        _lastHrBpm = hrNow;

        // Derive batch size from whichever primary sensor has data.
        var batchSize = 0;
        if (accel != null && accel.x != null) {
            batchSize = accel.x.size();
        } else if (gyro != null && gyro.x != null) {
            batchSize = gyro.x.size();
        } else if (mag != null && mag.x != null) {
            batchSize = mag.x.size() * MAG_DOWNSAMPLE_RATIO;
        }
        if (batchSize == 0) { return; }

        var periodMs = 1000 / PRIMARY_RATE_HZ;

        var accX = (accel != null) ? accel.x : null;
        var accY = (accel != null) ? accel.y : null;
        var accZ = (accel != null) ? accel.z : null;
        var gyrX = (gyro  != null) ? gyro.x  : null;
        var gyrY = (gyro  != null) ? gyro.y  : null;
        var gyrZ = (gyro  != null) ? gyro.z  : null;
        var magX = (mag   != null) ? mag.x   : null;
        var magY = (mag   != null) ? mag.y   : null;
        var magZ = (mag   != null) ? mag.z   : null;

        for (var i = 0; i < batchSize; i++) {
            var magI = i / MAG_DOWNSAMPLE_RATIO;

            var sample = {
                "t"  => periodMs,
                "ax" => _safeFloat(accX, i),
                "ay" => _safeFloat(accY, i),
                "az" => _safeFloat(accZ, i),
                "gx" => _safeFloat(gyrX, i),
                "gy" => _safeFloat(gyrY, i),
                "gz" => _safeFloat(gyrZ, i),
                "mx" => _safeFloat(magX, magI),
                "my" => _safeFloat(magY, magI),
                "mz" => _safeFloat(magZ, magI),
                "hr" => hrNow
            };

            // INVARIANT: _buffer.size() <= MAX_BUFFER_SIZE.
            if (_buffer.size() >= MAX_BUFFER_SIZE) {
                _buffer = _buffer.slice(1, null);
            }
            _buffer.add(sample);

            _callback.invoke(sample);
        }

        // Rolling 1-second frequency measurement.
        _sampleCount += batchSize;
        var elapsed = System.getTimer() - _freqWindowStart;
        if (elapsed >= 1000) {
            _measuredFrequency = _sampleCount.toFloat() / (elapsed / 1000.0f);
            _sampleCount       = 0;
            _freqWindowStart   = System.getTimer();
        }
    }

    //! Safe read of a batched axis array — returns 0.0 on any anomaly.
    private function _safeFloat(arr as Array?, i as Number) as Float {
        if (arr == null || i < 0 || i >= arr.size() || arr[i] == null) {
            return 0.0f;
        }
        return arr[i].toFloat();
    }

    // ── Buffer introspection ──────────────────────────────────────

    function getSamples() as Array<Dictionary> {
        return _buffer.slice(0, null);
    }

    function clearBuffer() as Void {
        _buffer = [] as Array<Dictionary>;
    }

    function getMeasuredFrequency() as Float { return _measuredFrequency; }
    function getBufferSize() as Number       { return _buffer.size(); }
    function isRegistered() as Boolean       { return _isRegistered; }

    function getLastRrIntervals() as Array<Number> or Null {
        return _lastRrIntervals;
    }

    function getLastHrBpm() as Number {
        return _lastHrBpm;
    }

    function hasRrIntervals() as Boolean {
        return _lastRrIntervals != null
            && (_lastRrIntervals as Array<Number>).size() > 0;
    }

    // ── Live sensor meta (FR-007) ─────────────────────────────────

    //! Poll real-time Sensor.Info values (pressure, altitude, temperature, etc.).
    //! Each field absent if the sensor is unavailable at call time.
    function getLiveSensorInfo() as Dictionary {
        var out = {} as Dictionary;
        var info = Sensor.getInfo();
        if (info == null) { return out; }

        if (info has :pressure    && info.pressure    != null) { out.put("pres_pa",     info.pressure.toNumber());  }
        if (info has :altitude    && info.altitude    != null) { out.put("alt_baro_m",  info.altitude.toFloat());   }
        if (info has :temperature && info.temperature != null) { out.put("temp_c",      info.temperature.toFloat());}
        if (info has :cadence     && info.cadence     != null) { out.put("cadence",     info.cadence.toNumber());   }
        if (info has :power       && info.power       != null) { out.put("power_w",     info.power.toNumber());     }
        if (info has :heading     && info.heading     != null) { out.put("heading_rad", info.heading.toFloat());    }
        return out;
    }

    //! Poll slow-updating ActivityMonitor fields (resp rate, stress, body batt).
    function getActivityMonitorInfo() as Dictionary {
        var out = {} as Dictionary;
        var ai = ActivityMonitor.getInfo();
        if (ai == null) { return out; }

        if (ai has :respirationRate  && ai.respirationRate  != null) { out.put("resp",       ai.respirationRate.toNumber()); }
        if (ai has :stressScore      && ai.stressScore      != null) { out.put("stress",     ai.stressScore.toNumber());     }
        if (ai has :bodyBatteryLevel && ai.bodyBatteryLevel != null) { out.put("body_batt",  ai.bodyBatteryLevel.toNumber());}
        if (ai has :steps            && ai.steps            != null) { out.put("steps_day",  ai.steps.toNumber());           }
        if (ai has :distance         && ai.distance         != null) {
            // ActivityMonitor distance is in cm → convert to metres.
            out.put("dist_day_m", (ai.distance.toNumber() / 100).toNumber());
        }
        if (ai has :floorsClimbed    && ai.floorsClimbed    != null) { out.put("floors_day", ai.floorsClimbed.toNumber()); }
        return out;
    }

    //! Fetch the user profile (weight, height, birth year, gender).
    function getUserProfile() as Dictionary {
        var out = {} as Dictionary;
        try {
            var prof = UserProfile.getProfile();
            if (prof == null) { return out; }
            if (prof has :weight    && prof.weight    != null) { out.put("weight_g",  prof.weight.toNumber()); }
            if (prof has :height    && prof.height    != null) { out.put("height_cm", prof.height.toNumber()); }
            if (prof has :birthYear && prof.birthYear != null) { out.put("birth_year",prof.birthYear.toNumber()); }
            if (prof has :gender    && prof.gender    != null) {
                out.put("gender",
                    prof.gender == UserProfile.GENDER_FEMALE ? "F" : "M");
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: UserProfile read failed: " + ex.getErrorMessage());
        }
        return out;
    }

    // ── History streams (FR-008) ──────────────────────────────────

    //! Read entries from a SensorHistoryIterator, newest first, capped at maxN.
    //! @param iter   SensorHistoryIterator (may be null if unsupported)
    //! @param maxN   Max entries to return
    //! @param minTsS Cutoff Unix seconds: stop when entry is older. 0 = no cutoff.
    private function _readHistory(iter, maxN as Number, minTsS as Number) as Array {
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
                if (minTsS > 0 && tsS > 0 && tsS < minTsS) {
                    break;  // newest-first: anything older than cutoff ends the scan.
                }
                out.add([tsS, s.data]);
                count++;
            }
        } catch (ex instanceof Lang.Exception) {
            System.println("SensorManager: history read failed: " + ex.getErrorMessage());
        }
        return out;
    }

    function getHrHistory(maxN as Number, minTsS as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getHeartRateHistory)) { return []; }
        var iter = Toybox.SensorHistory.getHeartRateHistory({
            :period => 1, :order => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN, minTsS);
    }

    function getHrvHistory(maxN as Number, minTsS as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getHeartRateVariabilityHistory)) { return []; }
        var iter = Toybox.SensorHistory.getHeartRateVariabilityHistory({
            :period => 1, :order => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN, minTsS);
    }

    function getSpo2History(maxN as Number, minTsS as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getOxygenSaturationHistory)) { return []; }
        var iter = Toybox.SensorHistory.getOxygenSaturationHistory({
            :period => 1, :order => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN, minTsS);
    }

    function getStressHistory(maxN as Number, minTsS as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getStressHistory)) { return []; }
        var iter = Toybox.SensorHistory.getStressHistory({
            :period => 1, :order => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN, minTsS);
    }

    function getPressureHistory(maxN as Number, minTsS as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getPressureHistory)) { return []; }
        var iter = Toybox.SensorHistory.getPressureHistory({
            :period => 1, :order => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN, minTsS);
    }

    function getTemperatureHistory(maxN as Number, minTsS as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getTemperatureHistory)) { return []; }
        var iter = Toybox.SensorHistory.getTemperatureHistory({
            :period => 1, :order => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN, minTsS);
    }

    function getElevationHistory(maxN as Number, minTsS as Number) as Array {
        if (!(Toybox has :SensorHistory)) { return []; }
        if (!(Toybox.SensorHistory has :getElevationHistory)) { return []; }
        var iter = Toybox.SensorHistory.getElevationHistory({
            :period => 1, :order => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        return _readHistory(iter, maxN, minTsS);
    }

    // ── SpO2 snapshot (FR-007) ────────────────────────────────────

    //! SpO2 is not a continuous sensor — this returns the newest entry from
    //! SensorHistory with its age. May be minutes or hours old.
    //! @return { "value" => % or null, "ageS" => seconds or null }
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

    // ── UI getters ────────────────────────────────────────────────

    function getImuQualityScore() as Number {
        var ratio = _measuredFrequency / PRIMARY_RATE_HZ.toFloat();
        if (ratio > 1.0f) { ratio = 1.0f; }
        var q = (ratio * 100.0f).toNumber();
        if (q < 0) { q = 0; }
        return q;
    }

    function getSampleRateSummary() as Dictionary {
        return {
            "accelHz"    => PRIMARY_RATE_HZ,
            "gyroHz"     => PRIMARY_RATE_HZ,
            "magHz"      => MAG_RATE_HZ,
            "measuredHz" => _measuredFrequency,
            "bufferSize" => _buffer.size()
        };
    }

    function getAccelWindow(maxPoints as Number) as Array { return _extractAxis("ax", maxPoints); }
    function getGyroWindow(maxPoints as Number)  as Array { return _extractAxis("gx", maxPoints); }
    function getMagWindow(maxPoints as Number)   as Array { return _extractAxis("mx", maxPoints); }

    private function _extractAxis(key as String, maxPoints as Number) as Array {
        var out = [] as Array;
        var size = _buffer.size();
        var start = size - maxPoints;
        if (start < 0) { start = 0; }
        for (var i = start; i < size; i++) {
            var s = _buffer[i] as Dictionary;
            var v = s.get(key);
            if (v != null) {
                out.add((v as Float));
            }
        }
        return out;
    }

    //! C-003 getAxisStats(key, maxPoints).
    //! Precondition: key in {ax,ay,az,gx,gy,gz,mx,my,mz,hr}; maxPoints > 0.
    //! Postcondition: returns {rms, max, min} over last min(maxPoints, buffer.size())
    //!   samples; returns zeros if buffer empty.
    function getAxisStats(key as String, maxPoints as Number) as Dictionary {
        var size = _buffer.size();
        if (size == 0) {
            return { "rms" => 0.0f, "max" => 0.0f, "min" => 0.0f };
        }
        var start = size - maxPoints;
        if (start < 0) { start = 0; }
        var sumSq = 0.0f;
        var maxV  = -999999.0f;
        var minV  =  999999.0f;
        var count = 0;
        for (var i = start; i < size; i++) {
            var s = _buffer[i] as Dictionary;
            var v = s.get(key);
            if (v == null) { continue; }
            var fv = (v as Float);
            sumSq += fv * fv;
            if (fv > maxV) { maxV = fv; }
            if (fv < minV) { minV = fv; }
            count++;
        }
        var rms = 0.0f;
        if (count > 0) {
            rms = Math.sqrt((sumSq / count.toFloat()).toDouble()).toFloat();
        }
        return { "rms" => rms, "max" => maxV, "min" => minV };
    }

    function getHrSnapshot() as Dictionary {
        var hr = 0;
        var info = Sensor.getInfo();
        if (info != null && (info has :heartRate) && info.heartRate != null) {
            hr = info.heartRate as Number;
        }
        return {
            "hr"     => hr,
            "hasRr"  => (_lastRrIntervals != null && _lastRrIntervals.size() > 0),
            "rrLast" => (_lastRrIntervals != null && _lastRrIntervals.size() > 0)
                           ? _lastRrIntervals[_lastRrIntervals.size() - 1]
                           : 0
        };
    }

    function getHrHistoryWindow(maxPoints as Number) as Array {
        var out = [] as Array;
        if (!(Toybox has :SensorHistory)) { return out; }
        if (!(Toybox.SensorHistory has :getHeartRateHistory)) { return out; }
        var iter = Toybox.SensorHistory.getHeartRateHistory({
            :period => 1, :order => Toybox.SensorHistory.ORDER_NEWEST_FIRST
        });
        if (iter == null) { return out; }
        var tmp = [] as Array;
        var count = 0;
        while (count < maxPoints) {
            var s = iter.next();
            if (s == null || s.data == null) { break; }
            tmp.add((s.data).toFloat());
            count++;
        }
        for (var i = tmp.size() - 1; i >= 0; i--) {
            out.add(tmp[i]);
        }
        return out;
    }

    //! Meta snapshot for UI screens — synchronous, may touch flash.
    //! NOT used in the sensor callback hot path; SessionManager caches the
    //! individual calls above (getSpo2Snapshot, getLiveSensorInfo, getActivityMonitorInfo).
    function getMetaSummary() as Dictionary {
        var out = {} as Dictionary;
        var info = Sensor.getInfo();
        if (info != null) {
            if ((info has :pressure)    && info.pressure    != null) { out.put("pres_pa",    info.pressure.toNumber());  }
            if ((info has :altitude)    && info.altitude    != null) { out.put("alt_m",      info.altitude.toFloat());   }
            if ((info has :temperature) && info.temperature != null) { out.put("temp_c",     info.temperature.toFloat());}
            if ((info has :heading)     && info.heading     != null) { out.put("heading_rad",info.heading.toFloat());    }
        }
        var ai = ActivityMonitor.getInfo();
        if (ai != null) {
            if ((ai has :respirationRate)  && ai.respirationRate  != null) { out.put("resp",      ai.respirationRate.toNumber()); }
            if ((ai has :stressScore)      && ai.stressScore      != null) { out.put("stress",    ai.stressScore.toNumber());     }
            if ((ai has :bodyBatteryLevel) && ai.bodyBatteryLevel != null) { out.put("body_batt", ai.bodyBatteryLevel.toNumber());}
            if ((ai has :steps)            && ai.steps            != null) { out.put("steps",     ai.steps.toNumber());           }
        }
        var spo2snap = getSpo2Snapshot();
        if (spo2snap.get("value") != null) {
            out.put("spo2", spo2snap.get("value"));
        }
        return out;
    }
}
