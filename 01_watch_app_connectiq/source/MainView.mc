import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;

//! Main view for GarminSensorCapture.
//! Displays: recording status, packet count, GPS fix, BLE link, errors.
class MainView extends WatchUi.View {

    //! Reference to session manager for reading state
    private var _sessionManager as SessionManager;

    //! Cache for loaded string resources
    private var _strIdle as String;
    private var _strRecording as String;
    private var _strStopping as String;
    private var _strPackets as String;
    private var _strGps as String;
    private var _strLink as String;
    private var _strError as String;
    private var _strGpsFix as String;
    private var _strGpsNoFix as String;
    private var _strConnected as String;
    private var _strDisconnected as String;

    //! @param sessionManager Shared session manager instance
    function initialize(sessionManager as SessionManager) {
        View.initialize();
        _sessionManager = sessionManager;

        // Pre-load string resources to avoid repeated lookup
        _strIdle        = WatchUi.loadResource(Rez.Strings.status_idle) as String;
        _strRecording   = WatchUi.loadResource(Rez.Strings.status_recording) as String;
        _strStopping    = WatchUi.loadResource(Rez.Strings.status_stopping) as String;
        _strPackets     = WatchUi.loadResource(Rez.Strings.label_packets) as String;
        _strGps         = WatchUi.loadResource(Rez.Strings.label_gps) as String;
        _strLink        = WatchUi.loadResource(Rez.Strings.label_link) as String;
        _strError       = WatchUi.loadResource(Rez.Strings.label_error) as String;
        _strGpsFix      = WatchUi.loadResource(Rez.Strings.gps_fix) as String;
        _strGpsNoFix    = WatchUi.loadResource(Rez.Strings.gps_nofix) as String;
        _strConnected   = WatchUi.loadResource(Rez.Strings.link_connected) as String;
        _strDisconnected = WatchUi.loadResource(Rez.Strings.link_disconnected) as String;
    }

    //! Called when the view needs to be laid out before first draw
    //! @param dc Device context used for dimension queries
    function onLayout(dc as Graphics.Dc) as Void {
        // No XML layout used — we draw everything programmatically
    }

    //! Called each time the view needs to be redrawn
    //! @param dc Device context for drawing operations
    function onUpdate(dc as Graphics.Dc) as Void {
        // Clear background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var width  = dc.getWidth();
        var height = dc.getHeight();
        var cx     = width / 2;

        // Retrieve current status snapshot
        var status = _sessionManager.getStatus();

        // ── Title bar ─────────────────────────────────────────────
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 10, Graphics.FONT_TINY,
                    "SENSOR CAPTURE", Graphics.TEXT_JUSTIFY_CENTER);

        // ── Status (IDLE / RECORDING / STOPPING) ─────────────────
        var stateStr = _strIdle;
        var stateColor = Graphics.COLOR_LT_GRAY;

        var state = status.get("state") as Number;
        if (state == SessionManager.STATE_RECORDING) {
            stateStr  = _strRecording;
            stateColor = Graphics.COLOR_GREEN;
        } else if (state == SessionManager.STATE_STOPPING) {
            stateStr  = _strStopping;
            stateColor = Graphics.COLOR_YELLOW;
        }

        dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, height / 2 - 45, Graphics.FONT_MEDIUM,
                    stateStr, Graphics.TEXT_JUSTIFY_CENTER);

        // ── Packet counter ────────────────────────────────────────
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var packetCount = status.get("packetCount") as Number;
        dc.drawText(cx, height / 2 - 15, Graphics.FONT_SMALL,
                    _strPackets + " " + packetCount.toString(),
                    Graphics.TEXT_JUSTIFY_CENTER);

        // ── GPS status ────────────────────────────────────────────
        var hasGps = status.get("hasGpsFix") as Boolean;
        var gpsStr = hasGps ? _strGpsFix : _strGpsNoFix;
        var gpsColor = hasGps ? Graphics.COLOR_GREEN : Graphics.COLOR_RED;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - 40, height / 2 + 10, Graphics.FONT_TINY,
                    _strGps, Graphics.TEXT_JUSTIFY_RIGHT);
        dc.setColor(gpsColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - 35, height / 2 + 10, Graphics.FONT_TINY,
                    gpsStr, Graphics.TEXT_JUSTIFY_LEFT);

        // ── BLE link status ───────────────────────────────────────
        var isLinked = status.get("isLinked") as Boolean;
        var linkStr = isLinked ? _strConnected : _strDisconnected;
        var linkColor = isLinked ? Graphics.COLOR_BLUE : Graphics.COLOR_RED;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - 40, height / 2 + 30, Graphics.FONT_TINY,
                    _strLink, Graphics.TEXT_JUSTIFY_RIGHT);
        dc.setColor(linkColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx - 35, height / 2 + 30, Graphics.FONT_TINY,
                    linkStr, Graphics.TEXT_JUSTIFY_LEFT);

        // ── Error count ───────────────────────────────────────────
        var errorCount = status.get("errorCount") as Number;
        if (errorCount > 0) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, height / 2 + 55, Graphics.FONT_TINY,
                        _strError + " " + errorCount.toString(),
                        Graphics.TEXT_JUSTIFY_CENTER);
        }

        // ── Battery indicator (small, bottom right) ───────────────
        var battery = System.getSystemStats().battery;
        var batColor = (battery < 20) ? Graphics.COLOR_RED : Graphics.COLOR_LT_GRAY;
        dc.setColor(batColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(width - 5, height - 20, Graphics.FONT_XTINY,
                    battery.format("%d") + "%",
                    Graphics.TEXT_JUSTIFY_RIGHT);

        // ── Hint: press START ─────────────────────────────────────
        if (state == SessionManager.STATE_IDLE) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, height - 25, Graphics.FONT_XTINY,
                        "PRESS START", Graphics.TEXT_JUSTIFY_CENTER);
        } else if (state == SessionManager.STATE_RECORDING) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, height - 25, Graphics.FONT_XTINY,
                        "PRESS BACK TO STOP", Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}
