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

    //! Cached localized strings (GIQ-072). Loaded ONCE here — NOT in onUpdate
    //! (GIQ-092: loadResource is expensive and MUST stay out of the hot draw path).
    private var _sRec;
    private var _sStop;
    private var _sIdle;
    private var _sBleOk;
    private var _sBleX;
    private var _sGpsOk;
    private var _sGpsNo;
    private var _sHintStart;
    private var _sHintStop;

    function initialize(sessionManager) {
        View.initialize();
        _session = sessionManager;
        _refreshTimer = new Timer.Timer();
        try {
            _sRec      = WatchUi.loadResource(Rez.Strings.status_recording);
            _sStop     = WatchUi.loadResource(Rez.Strings.status_stopping);
            _sIdle     = WatchUi.loadResource(Rez.Strings.status_idle);
            _sBleOk    = WatchUi.loadResource(Rez.Strings.link_up);
            _sBleX     = WatchUi.loadResource(Rez.Strings.link_down);
            _sGpsOk    = WatchUi.loadResource(Rez.Strings.gps_fix_short);
            _sGpsNo    = WatchUi.loadResource(Rez.Strings.gps_nofix_short);
            _sHintStart= WatchUi.loadResource(Rez.Strings.hint_press_start);
            _sHintStop = WatchUi.loadResource(Rez.Strings.hint_press_stop);
        } catch (ex instanceof Lang.Exception) {
            // Fallback to English hardcoded strings if a resource is missing at runtime.
            System.println("MainView: resource load err " + ex.getErrorMessage());
            _sRec       = "RECORDING";
            _sStop      = "STOPPING";
            _sIdle      = "READY";
            _sBleOk     = "BLE OK";
            _sBleX      = "BLE X";
            _sGpsOk     = "GPS FIX";
            _sGpsNo     = "GPS --";
            _sHintStart = "START to record";
            _sHintStop  = "START to stop";
        }
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
                stateStr = _sRec;
                stateColor = Graphics.COLOR_RED;
            } else if (state == SessionManager.STATE_STOPPING) {
                stateStr = _sStop;
                stateColor = Graphics.COLOR_ORANGE;
            } else {
                stateStr = _sIdle;
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
            var bleStr = _session.isLinkUp() ? _sBleOk : _sBleX;
            var gpsStr = _session.hasGpsFix() ? _sGpsOk : _sGpsNo;
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
            var hint = (state == SessionManager.STATE_IDLE) ? _sHintStart : _sHintStop;
            dc.drawText(cx, (h * 0.88).toNumber(), Graphics.FONT_XTINY, hint, Graphics.TEXT_JUSTIFY_CENTER);
        } catch (ex instanceof Lang.Exception) {
            System.println("MainView: onUpdate FATAL " + ex.getErrorMessage());
        }
    }
}
