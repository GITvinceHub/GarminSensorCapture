import Toybox.Position;
import Toybox.Lang;
import Toybox.System;
import Toybox.Math;
import Toybox.Time;

//! GPS subsystem — enables Position.LOCATION_CONTINUOUS (~1 Hz updates).
//!
//! Implements FR-006 (GPS 1 Hz) per SPECIFICATION.md §4.1.
//! NFR-012: onPosition is wrapped in try/catch and guards every :has check.
//!
//! Note: On fēnix 8 Pro (CIQ 5+) enableLocationEvents fires onPosition very
//! quickly (< 1 s) with a potentially incomplete Info object. All field
//! access is guarded with `has :` and null checks.
class PositionManager {

    typedef GpsCallback as Method(gpsData as Dictionary) as Void;

    private const RAD_TO_DEG     = 57.29577951308232f;
    private const MAX_FIX_AGE_MS = 5000;

    private var _callback     as GpsCallback;
    private var _lastFix      as Dictionary or Null;
    private var _lastFixTime  as Number;
    private var _isEnabled    as Boolean;
    private var _hasValidFix  as Boolean;

    function initialize(callback as GpsCallback) {
        _callback     = callback;
        _lastFix      = null;
        _lastFixTime  = 0;
        _isEnabled    = false;
        _hasValidFix  = false;
    }

    function enable() as Void {
        if (_isEnabled) { return; }
        try {
            Position.enableLocationEvents(
                Position.LOCATION_CONTINUOUS,
                method(:onPosition)
            );
            _isEnabled = true;
            System.println("PositionManager: enabled");
        } catch (ex instanceof Lang.Exception) {
            System.println("PositionManager: enable failed: " + ex.getErrorMessage());
            _isEnabled = false;
        }
    }

    function disable() as Void {
        if (!_isEnabled) { return; }
        try {
            Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
        } catch (ex instanceof Lang.Exception) {
            System.println("PositionManager: disable failed: " + ex.getErrorMessage());
        }
        _isEnabled   = false;
        _hasValidFix = false;
        System.println("PositionManager: disabled");
    }

    //! CIQ runtime callback — wrapped in try/catch per NFR-012.
    function onPosition(info as Position.Info) as Void {
        try {
            _onPositionImpl(info);
        } catch (ex instanceof Lang.Exception) {
            System.println("PositionManager: FATAL in onPosition: " + ex.getErrorMessage());
            // Swallow per NFR-013.
        }
    }

    private function _onPositionImpl(info as Position.Info) as Void {
        // Early-out on null/invalid Info (may happen on first fire).
        if (info == null) {
            _hasValidFix = false;
            return;
        }
        if (!(info has :accuracy) || info.accuracy == null
            || info.accuracy == Position.QUALITY_NOT_AVAILABLE) {
            _hasValidFix = false;
            return;
        }
        if (info.accuracy < Position.QUALITY_POOR) {
            _hasValidFix = false;
            return;
        }
        // Position object may be null before first real fix.
        if (!(info has :position) || info.position == null) {
            _hasValidFix = false;
            return;
        }

        _hasValidFix = true;
        _lastFixTime = System.getTimer();

        // Radians → degrees.
        var posArray = info.position.toRadians();
        var latDeg   = posArray[0].toFloat() * RAD_TO_DEG;
        var lonDeg   = posArray[1].toFloat() * RAD_TO_DEG;

        var altM   = 0.0f;
        var spdMs  = 0.0f;
        var hdgDeg = 0.0f;

        if (info has :altitude && info.altitude != null) { altM   = info.altitude.toFloat(); }
        if (info has :speed    && info.speed    != null) { spdMs  = info.speed.toFloat();    }
        if (info has :heading  && info.heading  != null) { hdgDeg = info.heading.toFloat();  }

        var accM = _mapQualityToAccuracy(info.accuracy);

        // Unix-epoch seconds.
        var tsUnix = 0l;
        if (info has :when && info.when != null) {
            tsUnix = info.when.value();
        } else {
            tsUnix = Time.now().value();
        }

        _lastFix = {
            "lat" => latDeg,
            "lon" => lonDeg,
            "alt" => altM,
            "spd" => spdMs,
            "hdg" => hdgDeg,
            "acc" => accM,
            "ts"  => tsUnix
        };

        _callback.invoke(_lastFix as Dictionary);
    }

    function getLastFix() as Dictionary or Null {
        if (!_hasValidFix || _lastFix == null) { return null; }
        var age = System.getTimer() - _lastFixTime;
        if (age > MAX_FIX_AGE_MS) {
            _hasValidFix = false;
            return null;
        }
        return _lastFix;
    }

    function hasValidFix() as Boolean {
        if (!_hasValidFix) { return false; }
        var age = System.getTimer() - _lastFixTime;
        return age <= MAX_FIX_AGE_MS;
    }

    function getFixAgeMs() as Number {
        if (_lastFixTime == 0) { return -1; }
        return System.getTimer() - _lastFixTime;
    }

    function isEnabled() as Boolean { return _isEnabled; }

    private function _mapQualityToAccuracy(quality as Number) as Float {
        if (quality == Position.QUALITY_GOOD)   { return 5.0f;  }
        if (quality == Position.QUALITY_USABLE) { return 15.0f; }
        if (quality == Position.QUALITY_POOR)   { return 50.0f; }
        return 100.0f;
    }

    function getQualityScore() as Number {
        if (!_hasValidFix || _lastFix == null) { return 0; }
        var age = System.getTimer() - _lastFixTime;
        if (age > MAX_FIX_AGE_MS) { return 0; }
        var acc = _lastFix.get("acc");
        if (acc == null) { return 50; }
        var accVal = (acc as Float);
        if (accVal <= 5.0f)  { return 95; }
        if (accVal <= 15.0f) { return 75; }
        if (accVal <= 50.0f) { return 40; }
        return 20;
    }

    function getUiSnapshot() as Dictionary {
        var hasF = hasValidFix();
        if (!hasF || _lastFix == null) {
            return {
                "hasValidFix" => false,
                "lat"    => 0.0d,
                "lon"    => 0.0d,
                "alt"    => 0.0f,
                "spd"    => 0.0f,
                "hdg"    => 0.0f,
                "acc"    => 0.0f,
                "fixAge" => -1
            };
        }
        var fix = _lastFix as Dictionary;
        return {
            "hasValidFix" => true,
            "lat"    => fix.get("lat"),
            "lon"    => fix.get("lon"),
            "alt"    => fix.get("alt"),
            "spd"    => fix.get("spd"),
            "hdg"    => fix.get("hdg"),
            "acc"    => fix.get("acc"),
            "fixAge" => System.getTimer() - _lastFixTime
        };
    }
}
