import Toybox.Lang;
import Toybox.Graphics;

//! Transforms raw sensor / session data into display-ready values.
//!
//! Quality scores (0–100):
//!   IMU     = measured Hz / target Hz × 100, minus error penalties
//!   GPS     = 0 (no fix) / 40 (poor) / 75 (usable) / 95 (good), age penalty
//!   HR      = 0 (no HR) / 80 (HR only) / 95 (HR + RR intervals)
//!   BLE     = 100 when linked, minus 5 per queued packet above 5
//!   Overall = 40 % IMU + 30 % GPS + 20 % BLE + 10 % HR
//!
//! Formatting helpers: duration, file size, speed.
class ViewModel {

    //! Quality thresholds that drive colour
    static const Q_WARN  = 80;
    static const Q_ERROR = 50;

    function initialize() {}

    // ── Quality computations ──────────────────────────────────────

    //! IMU quality based on measured vs target sample rate + error count.
    function computeImuQuality(status as Dictionary) as Number {
        var measured = status.get("imuFreqHz");
        if (measured == null) { return 50; }
        var freq = (measured as Float);
        var ratio = freq / 100.0f;
        if (ratio > 1.0f) { ratio = 1.0f; }
        var q = (ratio * 100.0f).toNumber();
        var errCount = status.get("errorCount");
        if (errCount != null) {
            q -= (errCount as Number) * 3;
        }
        if (q < 0) { q = 0; }
        return q;
    }

    //! GPS quality derived from fix validity, quality level, and fix age.
    function computeGpsQuality(status as Dictionary) as Number {
        var hasGps = status.get("hasGpsFix");
        if (hasGps == null || !(hasGps as Boolean)) { return 0; }
        var gpsQ = status.get("gpsQualityScore");
        if (gpsQ != null) { return (gpsQ as Number); }
        return 75;
    }

    //! HR data quality: 0 if no HR, 95 if HR + RR, 80 if HR only.
    function computeHrQuality(status as Dictionary) as Number {
        var hr = status.get("lastHr");
        if (hr == null || (hr as Number) == 0) { return 0; }
        var hasRr = status.get("hasRrIntervals");
        if (hasRr != null && (hasRr as Boolean)) { return 95; }
        return 80;
    }

    //! BLE link quality: 100 when linked, decrements for queued packets.
    function computeBleQuality(status as Dictionary) as Number {
        var linked = status.get("isLinked");
        if (linked == null || !(linked as Boolean)) { return 0; }
        var qs = status.get("commQueueSize");
        var q = 100;
        if (qs != null) {
            var excess = (qs as Number) - 5;
            if (excess > 0) { q -= excess * 5; }
        }
        if (q < 0) { q = 0; }
        return q;
    }

    //! Overall quality: 40 % IMU + 30 % GPS + 20 % BLE + 10 % HR.
    function computeOverallQuality(status as Dictionary) as Number {
        var imu = computeImuQuality(status);
        var gps = computeGpsQuality(status);
        var ble = computeBleQuality(status);
        var hr  = computeHrQuality(status);
        return (imu * 40 + gps * 30 + ble * 20 + hr * 10) / 100;
    }

    //! Buffer quality: based on dropped samples and in-memory queue saturation.
    //! 100 = no drops, no saturation; degrades with each dropped sample or full queue.
    function computeBufferQuality(status as Dictionary) as Number {
        var q = 100;
        var dropped = status.get("droppedSamples");
        if (dropped != null && (dropped as Number) > 0) {
            var penalty = (dropped as Number) * 2;
            if (penalty > 50) { penalty = 50; }
            q -= penalty;
        }
        var queueSz = status.get("commQueueSize");
        if (queueSz != null) {
            var sz = queueSz as Number;
            if (sz >= 15) { q -= 30; }
            else if (sz >= 10) { q -= 15; }
            else if (sz >= 5)  { q -= 5; }
        }
        if (q < 0) { q = 0; }
        return q;
    }

    //! Integrity quality: based on error count, dropped samples, send failures.
    //! 100 = no errors; penalises by type.
    function computeIntegrityQuality(status as Dictionary) as Number {
        var q = 100;
        var errCount = status.get("errorCount");
        if (errCount != null) {
            var penalty = (errCount as Number) * 5;
            if (penalty > 40) { penalty = 40; }
            q -= penalty;
        }
        var dropped = status.get("droppedSamples");
        if (dropped != null) {
            var penalty2 = (dropped as Number) * 3;
            if (penalty2 > 30) { penalty2 = 30; }
            q -= penalty2;
        }
        var failures = status.get("commSendFailures");
        if (failures != null) {
            var penalty3 = (failures as Number) * 2;
            if (penalty3 > 20) { penalty3 = 20; }
            q -= penalty3;
        }
        if (q < 0) { q = 0; }
        return q;
    }

    //! Power quality: based on battery percentage.
    //! 100 = >50%, 75 = 25-50%, 50 = 10-25%, 20 = <10%.
    function computePowerQuality(status as Dictionary) as Number {
        var bat = status.get("battery");
        if (bat == null) { return 75; }
        var pct = bat as Number;
        if (pct > 50) { return 100; }
        if (pct > 25) { return 75; }
        if (pct > 10) { return 50; }
        return 20;
    }

    //! Pipeline quality: composite of all subsystems.
    //! 30 % IMU + 25 % BLE + 20 % integrity + 15 % GPS + 10 % power.
    function computePipelineQuality(status as Dictionary) as Number {
        var imu  = computeImuQuality(status);
        var ble  = computeBleQuality(status);
        var intg = computeIntegrityQuality(status);
        var gps  = computeGpsQuality(status);
        var pwr  = computePowerQuality(status);
        return (imu * 30 + ble * 25 + intg * 20 + gps * 15 + pwr * 10) / 100;
    }

    //! Return the appropriate colour for a quality value.
    function qualityColor(q as Number) as Number {
        if (q >= Q_WARN)  { return Graphics.COLOR_GREEN; }
        if (q >= Q_ERROR) { return Graphics.COLOR_ORANGE; }
        return Graphics.COLOR_RED;
    }

    // ── Formatting helpers ────────────────────────────────────────

    //! Format elapsed milliseconds as "HH:MM:SS".
    function formatDuration(ms as Number) as String {
        var totalS = ms / 1000;
        var h = totalS / 3600;
        var m = (totalS % 3600) / 60;
        var s = totalS % 60;
        return h.format("%02d") + ":" + m.format("%02d") + ":" + s.format("%02d");
    }

    //! Format a byte count into a human-readable string.
    function formatFileSize(bytes as Number) as String {
        if (bytes < 1024) {
            return bytes.toString() + " B";
        }
        if (bytes < 1048576) {
            var kb = bytes / 1024;
            return kb.format("%d") + " KB";
        }
        var mbF = (bytes.toFloat()) / 1048576.0f;
        return mbF.format("%.1f") + " MB";
    }

    //! Format speed in m/s to "XX.X km/h".
    function formatSpeed(mps as Float) as String {
        return (mps * 3.6f).format("%.1f") + " km/h";
    }

    //! Format a heading in degrees to "XXX°".
    function formatHeading(deg as Float) as String {
        return deg.format("%.0f") + "\u00B0";
    }

    //! Format lat or lon degrees to signed decimal with 5 decimal places.
    function formatCoord(deg as Double) as String {
        return deg.format("%.5f");
    }

    //! Format a pressure in Pa to "XXXX.X hPa".
    function formatPressure(pa as Number) as String {
        var hpa = pa.toFloat() / 100.0f;
        return hpa.format("%.1f") + " hPa";
    }
}
