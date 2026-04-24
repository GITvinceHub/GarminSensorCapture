import Toybox.Position;
import Toybox.Lang;
import Toybox.System;
import Toybox.Math;
import Toybox.Time;

//! Manages GPS position data.
//! Uses Toybox.Position with LOCATION_CONTINUOUS for ~1Hz updates.
//!
//! HYPOTHESIS H-003: GPS at 1 Hz via LOCATION_CONTINUOUS
//! Note: lat/lon from Position.Info are in radians → converted to degrees here.
class PositionManager {

    //! Callback type: called when a new GPS fix is available
    typedef GpsCallback as Method(gpsData as Dictionary) as Void;

    //! Conversion constant: radians to degrees
    private const RAD_TO_DEG = 57.29577951308232f;

    //! Maximum age of a GPS fix before it is considered stale (ms)
    private const MAX_FIX_AGE_MS = 5000;

    //! Callback to notify SessionManager
    private var _callback as GpsCallback;

    //! Last valid GPS fix data dictionary
    private var _lastFix as Dictionary or Null;

    //! Timestamp when the last fix was received (System.getTimer())
    private var _lastFixTime as Number;

    //! Whether position events are currently enabled
    private var _isEnabled as Boolean;

    //! Whether the last fix was valid (quality check)
    private var _hasValidFix as Boolean;

    //! @param callback Function called on each new GPS fix
    function initialize(callback as GpsCallback) {
        _callback      = callback;
        _lastFix       = null;
        _lastFixTime   = 0;
        _isEnabled     = false;
        _hasValidFix   = false;
    }

    //! Enable continuous location events. Called when session starts.
    function enable() as Void {
        if (_isEnabled) {
            return;
        }
        Position.enableLocationEvents(
            Position.LOCATION_CONTINUOUS,
            method(:onPosition)
        );
        _isEnabled = true;
        System.println("PositionManager: enabled");
    }

    //! Disable location events. Called when session stops.
    function disable() as Void {
        if (!_isEnabled) {
            return;
        }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
        _isEnabled   = false;
        _hasValidFix = false;
        System.println("PositionManager: disabled");
    }

    //! GPS callback — called by Connect IQ runtime on each new position.
    //! @param info Position.Info object with GPS data
    function onPosition(info as Position.Info) as Void {
        // Check fix quality
        if (info == null || info.accuracy == Position.QUALITY_NOT_AVAILABLE) {
            _hasValidFix = false;
            return;
        }

        // Accept POOR quality or better (QUALITY_POOR = 1, QUALITY_USABLE = 2, QUALITY_GOOD = 3)
        if (info.accuracy < Position.QUALITY_POOR) {
            _hasValidFix = false;
            return;
        }

        _hasValidFix = true;
        _lastFixTime = System.getTimer();

        // ── Convert lat/lon from radians to degrees ───────────────
        var posArray = info.position.toRadians();
        var latDeg = posArray[0].toFloat() * RAD_TO_DEG;
        var lonDeg = posArray[1].toFloat() * RAD_TO_DEG;

        // ── Extract optional fields ───────────────────────────────
        var altM  = 0.0f;
        var spdMs = 0.0f;
        var hdgDeg = 0.0f;
        var accM  = 0.0f;

        if (info has :altitude && info.altitude != null) {
            altM = info.altitude.toFloat();
        }
        if (info has :speed && info.speed != null) {
            spdMs = info.speed.toFloat();
        }
        if (info has :heading && info.heading != null) {
            hdgDeg = info.heading.toFloat();
        }
        // Horizontal accuracy from quality enum (approximate mapping)
        accM = _mapQualityToAccuracy(info.accuracy);

        // ── Get GPS timestamp (Unix epoch seconds) ────────────────
        var tsUnix = 0l;
        if (info has :when && info.when != null) {
            tsUnix = info.when.value();
        } else {
            // Fallback: use system time
            tsUnix = Time.now().value();
        }

        // ── Build GPS data dictionary ─────────────────────────────
        _lastFix = {
            "lat" => latDeg,
            "lon" => lonDeg,
            "alt" => altM,
            "spd" => spdMs,
            "hdg" => hdgDeg,
            "acc" => accM,
            "ts"  => tsUnix
        };

        // Notify callback
        _callback.invoke(_lastFix as Dictionary);
    }

    //! Get the last valid GPS fix.
    //! @return Dictionary with GPS data, or null if no valid fix
    function getLastFix() as Dictionary or Null {
        if (!_hasValidFix || _lastFix == null) {
            return null;
        }

        // Check staleness
        var age = System.getTimer() - _lastFixTime;
        if (age > MAX_FIX_AGE_MS) {
            _hasValidFix = false;
            return null;
        }

        return _lastFix;
    }

    //! Check if a valid (non-stale) GPS fix is available.
    //! @return true if valid fix exists
    function hasValidFix() as Boolean {
        if (!_hasValidFix) {
            return false;
        }
        var age = System.getTimer() - _lastFixTime;
        return age <= MAX_FIX_AGE_MS;
    }

    //! Get age of last fix in milliseconds.
    //! @return Age in ms, or -1 if no fix
    function getFixAgeMs() as Number {
        if (_lastFixTime == 0) {
            return -1;
        }
        return System.getTimer() - _lastFixTime;
    }

    //! Map Position quality enum to approximate horizontal accuracy in meters.
    //! @param quality Position.QUALITY_* constant
    //! @return Approximate accuracy in meters
    private function _mapQualityToAccuracy(quality as Number) as Float {
        if (quality == Position.QUALITY_GOOD) {
            return 5.0f;
        } else if (quality == Position.QUALITY_USABLE) {
            return 15.0f;
        } else if (quality == Position.QUALITY_POOR) {
            return 50.0f;
        }
        return 100.0f;
    }

    //! Check if position tracking is currently active.
    //! @return true if enabled
    function isEnabled() as Boolean {
        return _isEnabled;
    }

    //! GPS quality score for UI display (0–100).
    //! Derived from the Position.QUALITY_* level of the last fix.
    //! Returns 0 if no valid fix.
    function getQualityScore() as Number {
        if (!_hasValidFix || _lastFix == null) { return 0; }
        var age = System.getTimer() - _lastFixTime;
        if (age > MAX_FIX_AGE_MS) { return 0; }
        var acc = _lastFix.get("acc");
        if (acc == null) { return 50; }
        var accVal = (acc as Float);
        // Map accuracy radius → quality score
        if (accVal <= 5.0f)  { return 95; }   // GOOD
        if (accVal <= 15.0f) { return 75; }   // USABLE
        if (accVal <= 50.0f) { return 40; }   // POOR
        return 20;
    }

    //! Return a snapshot Dictionary ready for UI rendering.
    //! Keys: lat, lon, alt, spd, hdg, acc, fixAge, hasValidFix
    function getUiSnapshot() as Dictionary {
        var hasF = hasValidFix();
        if (!hasF || _lastFix == null) {
            return {
                "hasValidFix" => false,
                "lat"  => 0.0d,
                "lon"  => 0.0d,
                "alt"  => 0.0f,
                "spd"  => 0.0f,
                "hdg"  => 0.0f,
                "acc"  => 0.0f,
                "fixAge" => -1
            };
        }
        var fix = _lastFix as Dictionary;
        return {
            "hasValidFix" => true,
            "lat"     => fix.get("lat"),
            "lon"     => fix.get("lon"),
            "alt"     => fix.get("alt"),
            "spd"     => fix.get("spd"),
            "hdg"     => fix.get("hdg"),
            "acc"     => fix.get("acc"),
            "fixAge"  => System.getTimer() - _lastFixTime
        };
    }
}
