//! MainView.mc
//! Single KISS status screen (spec §3 rewrite: no 14-screen UI).
//! Shows: state, packets, GPS, BLE, errors, battery.
//! Auto-refreshes at 2 Hz when recording (FR-029).
using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Timer;
using Toybox.Lang;

class MainView extends WatchUi.View {

    public static const REFRESH_INTERVAL_MS = 500;   // FR-029: 2 Hz

    private var _session;
    private var _refreshTimer;

    function initialize(sessionManager) {
        View.initialize();
        _session = sessionManager;
        _refreshTimer = new Timer.Timer();
    }

    function onLayout(dc) {
        // No layout resources — we draw everything in onUpdate.
    }

    function onShow() {
        try {
            _refreshTimer.start(method(:_onRefresh), REFRESH_INTERVAL_MS, true);
        } catch (ex instanceof Lang.Exception) {
            System.println("MainView: onShow err " + ex.getErrorMessage());
        }
    }

    function onHide() {
        try {
            _refreshTimer.stop();
        } catch (ex instanceof Lang.Exception) {
            System.println("MainView: onHide err " + ex.getErrorMessage());
        }
    }

    function _onRefresh() {
        try {
            WatchUi.requestUpdate();
        } catch (ex instanceof Lang.Exception) {
            System.println("MainView: _onRefresh err " + ex.getErrorMessage());
        }
    }

    function onUpdate(dc) {
        try {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();

            var w = dc.getWidth();
            var h = dc.getHeight();
            var cx = w / 2;

            var state = (_session != null) ? _session.getState() : SessionManager.STATE_IDLE;
            var stateStr;
            var stateColor;
            if (state == SessionManager.STATE_RECORDING) {
                stateStr = "RECORDING";
                stateColor = Graphics.COLOR_RED;
            } else if (state == SessionManager.STATE_STOPPING) {
                stateStr = "STOPPING";
                stateColor = Graphics.COLOR_ORANGE;
            } else {
                stateStr = "READY";
                stateColor = Graphics.COLOR_GREEN;
            }

            // Row 1: state.
            dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.10).toNumber(), Graphics.FONT_MEDIUM, stateStr, Graphics.TEXT_JUSTIFY_CENTER);

            if (_session == null) {
                return;
            }

            // Row 2: elapsed time.
            var elapsed = _session.getElapsedSec();
            var hrs = elapsed / 3600;
            var mins = (elapsed / 60) % 60;
            var secs = elapsed % 60;
            var timeStr = hrs.format("%02d") + ":" + mins.format("%02d") + ":" + secs.format("%02d");
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.22).toNumber(), Graphics.FONT_LARGE, timeStr, Graphics.TEXT_JUSTIFY_CENTER);

            // Row 3: packets sent / failed / queue.
            var pSent = _session.getPacketsSent();
            var pFail = _session.getPacketsFailed();
            var qSize = _session.getQueueSize();
            var bufSize = _session.getBufferSize();
            var pktStr = "PKT " + pSent + "/" + pFail + "  Q" + qSize + " B" + bufSize;
            dc.drawText(cx, (h * 0.38).toNumber(), Graphics.FONT_XTINY, pktStr, Graphics.TEXT_JUSTIFY_CENTER);

            // Row 4: BLE / GPS indicators.
            var bleStr = _session.isLinkUp() ? "BLE OK" : "BLE X";
            var gpsStr = _session.hasGpsFix() ? "GPS FIX" : "GPS --";
            dc.setColor(_session.isLinkUp() ? Graphics.COLOR_GREEN : Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText((w * 0.30).toNumber(), (h * 0.52).toNumber(), Graphics.FONT_XTINY, bleStr, Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(_session.hasGpsFix() ? Graphics.COLOR_GREEN : Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
            dc.drawText((w * 0.70).toNumber(), (h * 0.52).toNumber(), Graphics.FONT_XTINY, gpsStr, Graphics.TEXT_JUSTIFY_CENTER);

            // Row 5: HR + battery.
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            var hr = _session.getLastHrBpm();
            var bat = _session.getBattery();
            var hrBatStr = "HR " + hr + "   BAT " + bat + "%";
            dc.drawText(cx, (h * 0.64).toNumber(), Graphics.FONT_XTINY, hrBatStr, Graphics.TEXT_JUSTIFY_CENTER);

            // Row 6: errors (only if any).
            var errCount = _session.getErrorCount();
            if (errCount > 0) {
                dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, (h * 0.76).toNumber(), Graphics.FONT_XTINY, "ERR " + errCount, Graphics.TEXT_JUSTIFY_CENTER);
            }

            // Row 7: hint.
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            var hint = (state == SessionManager.STATE_IDLE) ? "START to record" : "START to stop";
            dc.drawText(cx, (h * 0.88).toNumber(), Graphics.FONT_XTINY, hint, Graphics.TEXT_JUSTIFY_CENTER);
        } catch (ex instanceof Lang.Exception) {
            System.println("MainView: onUpdate FATAL " + ex.getErrorMessage());
        }
    }
}
