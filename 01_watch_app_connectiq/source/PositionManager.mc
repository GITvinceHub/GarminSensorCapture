//! PositionManager.mc
//! GPS 1 Hz — enables Position, caches the last fix, exposes a dict the serializer reads.
//!
//! FR-006: lat, lon, alt, spd, hdg at ~1 Hz.
//! Callback is try/catch wrapped (NFR-012).
using Toybox.Position;
using Toybox.Lang;
using Toybox.System;
using Toybox.Time;

class PositionManager {

    private var _enabled;
    private var _lastFix;       // Dictionary or null
    private var _errorCount;

    function initialize() {
        _enabled = false;
        _lastFix = null;
        _errorCount = 0;
    }

    function enable() {
        if (_enabled) { return; }
        try {
            Position.enableLocationEvents(
                Position.LOCATION_CONTINUOUS,
                method(:onPosition)
            );
            _enabled = true;
            System.println("PositionManager: enabled");
        } catch (ex instanceof Lang.Exception) {
            System.println("PositionManager: enable FAILED " + ex.getErrorMessage());
            _enabled = false;
            _errorCount += 1;
        }
    }

    function disable() {
        if (!_enabled) { return; }
        try {
            Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
        } catch (ex instanceof Lang.Exception) {
            System.println("PositionManager: disable err " + ex.getErrorMessage());
        }
        _enabled = false;
    }

    //! CIQ callback — keep it small.
    function onPosition(info as Position.Info) as Void {
        try {
            if (info == null) { return; }
            var loc = info.position;
            if (loc == null) { return; }

            var degs = loc.toDegrees();
            var fix = {
                "lat" => degs[0],
                "lon" => degs[1],
                "alt" => info.altitude != null ? info.altitude : 0.0,
                "spd" => info.speed != null ? info.speed : 0.0,
                "hdg" => info.heading != null ? info.heading : 0.0,
                "acc" => info.accuracy != null ? info.accuracy : 0,
                "ts"  => Time.now().value()
            };
            _lastFix = fix;
        } catch (ex instanceof Lang.Exception) {
            System.println("PositionManager: onPosition FATAL " + ex.getErrorMessage());
            _errorCount += 1;
        }
    }

    //! Returns the cached fix (may be null if no fix yet). Safe to read from any thread.
    function getLastFix() {
        return _lastFix;
    }

    function isEnabled() { return _enabled; }
    function getErrorCount() { return _errorCount; }
}
