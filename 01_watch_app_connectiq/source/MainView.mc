import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;

//! Main view for GarminSensorCapture — 6-screen UI.
//!
//! Screen routing (UiState.SCREEN_*):
//!   0  Home        — session status, frequencies, BLE/GPS/HR summary
//!   1  IMU         — accel/gyro/mag Hz + sparklines; DOWN to cycle stats
//!   2  GPS         — lat/lon/alt/speed/heading + quality
//!   3  HR          — HR bpm, HRV, RR, mini graph
//!   4  Meta        — battery, pressure, temp, stress, SpO2
//!   5  Recording   — session stats: packets, losses, file size, quality
//!
//! All drawing is programmatic (no XML layout).
//! Layout is designed for a 454 × 454 round AMOLED (fēnix 8 Pro).
class MainView extends WatchUi.View {

    private var _sessionManager as SessionManager;
    private var _viewModel      as ViewModel;
    private var _uiState        as UiState;

    // ── Cached screen dimensions (set in onLayout) ────────────────
    private var _w  as Number;
    private var _h  as Number;
    private var _cx as Number;
    private var _cy as Number;

    //! @param sessionManager Shared session manager
    //! @param viewModel      Shared view model
    //! @param uiState        Shared UI navigation state
    function initialize(
        sessionManager as SessionManager,
        viewModel      as ViewModel,
        uiState        as UiState
    ) {
        View.initialize();
        _sessionManager = sessionManager;
        _viewModel      = viewModel;
        _uiState        = uiState;
        _w  = 454;
        _h  = 454;
        _cx = 227;
        _cy = 227;
    }

    function onLayout(dc as Graphics.Dc) as Void {
        _w  = dc.getWidth();
        _h  = dc.getHeight();
        _cx = _w / 2;
        _cy = _h / 2;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var status = _sessionManager.getStatus();

        // ── Capture menu overlay (takes full screen) ──────────────
        if (_uiState.isMenuOpen()) {
            _drawMenu(dc, status);
            return;
        }

        // ── Screen routing ────────────────────────────────────────
        var screen = _uiState.getScreenIndex();
        if (screen == UiState.SCREEN_HOME) {
            _drawHome(dc, status);
        } else if (screen == UiState.SCREEN_IMU) {
            _drawImu(dc, status);
        } else if (screen == UiState.SCREEN_GPS) {
            _drawGps(dc, status);
        } else if (screen == UiState.SCREEN_HR) {
            _drawHr(dc, status);
        } else if (screen == UiState.SCREEN_META) {
            _drawMeta(dc, status);
        } else {
            _drawRecording(dc, status);
        }

        // ── Common overlays ───────────────────────────────────────
        _drawNavDots(dc);
        _drawButtonLockIndicator(dc);
    }

    // ══════════════════════════════════════════════════════════════
    // Screen 1 — Home
    // ══════════════════════════════════════════════════════════════
    private function _drawHome(dc as Graphics.Dc, status as Dictionary) as Void {
        var state    = status.get("state") as Number;
        var isRec    = (state == SessionManager.STATE_RECORDING);
        var elapsed  = status.get("elapsedMs") as Number;
        var lastHr   = status.get("lastHr") as Number;
        var hasGps   = status.get("hasGpsFix") as Boolean;
        var isLinked = status.get("isLinked") as Boolean;
        var battery  = System.getSystemStats().battery.toNumber();

        // ── Title / status ────────────────────────────────────────
        var titleStr   = isRec ? "ENREGISTREMENT" : "CAPTURE PRÊTE";
        var titleColor = isRec ? Graphics.COLOR_RED : Graphics.COLOR_GREEN;
        dc.setColor(titleColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 8, Graphics.FONT_TINY,
                    titleStr, Graphics.TEXT_JUSTIFY_CENTER);

        // ── Elapsed timer (large) ─────────────────────────────────
        var durStr = _viewModel.formatDuration(elapsed);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 4, Graphics.FONT_NUMBER_HOT,
                    durStr, Graphics.TEXT_JUSTIFY_CENTER);

        // ── Sensor rows ───────────────────────────────────────────
        var rowY  = _h / 2 - 10;
        var rowDy = 30;
        var labelX = _cx - 50;
        var valX   = _cx + 50;

        // IMU
        _drawLabelValue(dc, labelX, rowY,       "IMU",  "100 Hz", Graphics.COLOR_GREEN);
        // GPS
        var gpsColor = hasGps ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE;
        var gpsStr   = hasGps ? "1 Hz" : "NO FIX";
        _drawLabelValue(dc, labelX, rowY + rowDy, "GPS", gpsStr, gpsColor);
        // HR
        var hrColor  = (lastHr > 0) ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY;
        var hrStr    = (lastHr > 0) ? lastHr.format("%d") + " bpm" : "-- bpm";
        _drawLabelValue(dc, labelX, rowY + rowDy * 2, "HR", hrStr, hrColor);

        // ── Status bar ────────────────────────────────────────────
        var barY    = _h * 3 / 4 + 10;
        // BLE icon / state
        var bleColor = isLinked ? Graphics.COLOR_BLUE : Graphics.COLOR_DK_GRAY;
        dc.setColor(bleColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx - 55, barY, Graphics.FONT_TINY,
                    isLinked ? "\u00BB BLE" : "-- BLE", Graphics.TEXT_JUSTIFY_CENTER);
        // GPS icon
        dc.setColor(gpsColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, barY, Graphics.FONT_TINY,
                    hasGps ? "\u00D7 GPS" : "o GPS", Graphics.TEXT_JUSTIFY_CENTER);
        // Battery
        var batColor = (battery < 20) ? Graphics.COLOR_RED : Graphics.COLOR_LT_GRAY;
        dc.setColor(batColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx + 55, barY, Graphics.FONT_TINY,
                    battery.format("%d") + "%", Graphics.TEXT_JUSTIFY_CENTER);

        // ── Overall quality ───────────────────────────────────────
        var q = _viewModel.computeOverallQuality(status);
        _drawQuality(dc, q);
    }

    // ══════════════════════════════════════════════════════════════
    // Screen 2 — IMU sensors
    // ══════════════════════════════════════════════════════════════
    private function _drawImu(dc as Graphics.Dc, status as Dictionary) as Void {
        var detail = _uiState.getDetailIndex();

        // Title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 12, Graphics.FONT_SMALL,
                    "IMU", Graphics.TEXT_JUSTIFY_CENTER);

        var sm = _sessionManager.getSensorManager();

        if (detail == UiState.IMU_DETAIL_OVERVIEW) {
            _drawImuOverview(dc, status, sm);
        } else if (detail == UiState.IMU_DETAIL_ACC) {
            _drawImuStats(dc, sm, "ax", "ACC  Accéléromètre");
        } else if (detail == UiState.IMU_DETAIL_GYRO) {
            _drawImuStats(dc, sm, "gx", "GYRO  Gyroscope");
        } else {
            _drawImuStats(dc, sm, "mx", "MAG  Magnétomètre");
        }

        var q = _viewModel.computeImuQuality(status);
        _drawQuality(dc, q);
    }

    private function _drawImuOverview(
        dc     as Graphics.Dc,
        status as Dictionary,
        sm     as SensorManager or Null
    ) as Void {
        var imuFreq = status.get("imuFreqHz");
        var measHz  = (imuFreq != null) ? (imuFreq as Float).format("%.0f") : "---";

        var rowY  = _h / 4;
        var rowDy = 55;

        // ACC row
        _drawSensorRow(dc, rowY,
            "ACC", measHz + " Hz", Graphics.COLOR_GREEN,
            sm != null ? sm.getAccelWindow(20) : ([] as Array));
        // GYRO row
        _drawSensorRow(dc, rowY + rowDy,
            "GYRO", measHz + " Hz", Graphics.COLOR_BLUE,
            sm != null ? sm.getGyroWindow(20) : ([] as Array));
        // MAG row
        _drawSensorRow(dc, rowY + rowDy * 2,
            "MAG", "50 Hz", Graphics.COLOR_ORANGE,
            sm != null ? sm.getMagWindow(20) : ([] as Array));

        // Hint
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h * 7 / 8, Graphics.FONT_XTINY,
                    "DOWN: détails capteur", Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function _drawSensorRow(
        dc     as Graphics.Dc,
        y      as Number,
        label  as String,
        rateStr as String,
        color  as Number,
        window as Array
    ) as Void {
        // Label
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx - 90, y, Graphics.FONT_TINY,
                    label, Graphics.TEXT_JUSTIFY_LEFT);
        // Rate
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx - 10, y, Graphics.FONT_TINY,
                    rateStr, Graphics.TEXT_JUSTIFY_LEFT);
        // Mini sparkline (right side)
        _drawSparkline(dc, window, _cx + 80, y + 10, color);
    }

    private function _drawImuStats(
        dc    as Graphics.Dc,
        sm    as SensorManager or Null,
        axis  as String,
        title as String
    ) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 6, Graphics.FONT_TINY,
                    title, Graphics.TEXT_JUSTIFY_CENTER);

        var stats = (sm != null)
            ? sm.getAxisStats(axis, 100)
            : ({ "rms" => 0.0f, "max" => 0.0f, "min" => 0.0f } as Dictionary);

        var rms = stats.get("rms") as Float;
        var mx  = stats.get("max") as Float;
        var mn  = stats.get("min") as Float;

        var midY = _cy;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, midY - 45, Graphics.FONT_TINY,
                    "RMS  " + rms.format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, midY - 5, Graphics.FONT_TINY,
                    "MAX  " + mx.format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, midY + 35, Graphics.FONT_TINY,
                    "MIN  " + mn.format("%.1f"), Graphics.TEXT_JUSTIFY_CENTER);
    }

    // ══════════════════════════════════════════════════════════════
    // Screen 3 — GPS / Position
    // ══════════════════════════════════════════════════════════════
    private function _drawGps(dc as Graphics.Dc, status as Dictionary) as Void {
        var pm = _sessionManager.getPositionManager();
        var snap = (pm != null)
            ? (pm as PositionManager).getUiSnapshot()
            : ({ "hasValidFix" => false } as Dictionary);

        var hasF = snap.get("hasValidFix") as Boolean;

        // Title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 12, Graphics.FONT_SMALL,
                    hasF ? "GPS 3D" : "GPS  NO FIX",
                    Graphics.TEXT_JUSTIFY_CENTER);

        if (!hasF) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_MEDIUM,
                        "En attente...", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            var lat = snap.get("lat");
            var lon = snap.get("lon");
            var alt = snap.get("alt");
            var spd = snap.get("spd");
            var hdg = snap.get("hdg");

            var latStr = (lat != null) ? _viewModel.formatCoord(lat as Double) + " N" : "---";
            var lonStr = (lon != null) ? _viewModel.formatCoord(lon as Double) + " E" : "---";
            var altStr = (alt != null) ? (alt as Float).format("%.0f") + " m" : "---";
            var spdStr = (spd != null) ? _viewModel.formatSpeed(spd as Float) : "---";
            var hdgStr = (hdg != null) ? _viewModel.formatHeading(hdg as Float) : "---";

            var rowY  = _h / 4;
            var rowDy = 38;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx - 60, rowY,            Graphics.FONT_TINY, "LAT", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(_cx - 60, rowY + rowDy,    Graphics.FONT_TINY, "LON", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(_cx - 60, rowY + rowDy*2,  Graphics.FONT_TINY, "ALT", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(_cx - 60, rowY + rowDy*3,  Graphics.FONT_TINY, "SPD", Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(_cx - 60, rowY + rowDy*4,  Graphics.FONT_TINY, "CAP", Graphics.TEXT_JUSTIFY_LEFT);

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx + 20, rowY,           Graphics.FONT_TINY, latStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(_cx + 20, rowY + rowDy,   Graphics.FONT_TINY, lonStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(_cx + 20, rowY + rowDy*2, Graphics.FONT_TINY, altStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(_cx + 20, rowY + rowDy*3, Graphics.FONT_TINY, spdStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(_cx + 20, rowY + rowDy*4, Graphics.FONT_TINY, hdgStr, Graphics.TEXT_JUSTIFY_LEFT);
        }

        var q = _viewModel.computeGpsQuality(status);
        _drawQuality(dc, q);
    }

    // ══════════════════════════════════════════════════════════════
    // Screen 4 — Heart rate
    // ══════════════════════════════════════════════════════════════
    private function _drawHr(dc as Graphics.Dc, status as Dictionary) as Void {
        var sm = _sessionManager.getSensorManager();
        var hrSnap = (sm != null)
            ? (sm as SensorManager).getHrSnapshot()
            : ({ "hr" => 0, "hasRr" => false, "rrLast" => 0 } as Dictionary);

        var hr    = hrSnap.get("hr") as Number;
        var hasRr = hrSnap.get("hasRr") as Boolean;
        var rrLast = hrSnap.get("rrLast") as Number;

        // Title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 12, Graphics.FONT_SMALL,
                    "FC", Graphics.TEXT_JUSTIFY_CENTER);

        // Heart symbol + BPM (large)
        var hrColor = (hr > 0) ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY;
        dc.setColor(hrColor, Graphics.COLOR_TRANSPARENT);
        var hrStr = (hr > 0) ? hr.format("%d") : "--";
        dc.drawText(_cx, _h / 4, Graphics.FONT_NUMBER_HOT,
                    hrStr, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(_cx, _h / 4 + 60, Graphics.FONT_TINY,
                    "bpm", Graphics.TEXT_JUSTIFY_CENTER);

        // HRV / RR
        var midY = _cy + 30;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx - 60, midY, Graphics.FONT_TINY,
                    "HRV", Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(_cx - 60, midY + 35, Graphics.FONT_TINY,
                    "RR", Graphics.TEXT_JUSTIFY_LEFT);

        dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx + 20, midY, Graphics.FONT_TINY,
                    hasRr ? "disponible" : "--", Graphics.TEXT_JUSTIFY_LEFT);

        var rrStr = (rrLast > 0) ? rrLast.format("%d") + " ms" : "-- ms";
        dc.drawText(_cx + 20, midY + 35, Graphics.FONT_TINY,
                    rrStr, Graphics.TEXT_JUSTIFY_LEFT);

        // Mini HR history graph
        if (sm != null) {
            var hrWindow = (sm as SensorManager).getHrHistoryWindow(20);
            if (hrWindow.size() > 0) {
                _drawMiniLineGraph(dc, hrWindow, _cx, _h * 3 / 4, 80, 30,
                                   Graphics.COLOR_RED);
            }
        }

        var q = _viewModel.computeHrQuality(status);
        _drawQuality(dc, q);
    }

    // ══════════════════════════════════════════════════════════════
    // Screen 5 — Metadata / Environment
    // ══════════════════════════════════════════════════════════════
    private function _drawMeta(dc as Graphics.Dc, status as Dictionary) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 12, Graphics.FONT_SMALL,
                    "MÉTADONNÉES", Graphics.TEXT_JUSTIFY_CENTER);

        var sm   = _sessionManager.getSensorManager();
        var meta = (sm != null)
            ? (sm as SensorManager).getMetaSummary()
            : ({} as Dictionary);

        var battery = System.getSystemStats().battery.toNumber();

        var rowY  = _h / 4;
        var rowDy = 34;
        var labX  = _cx - 70;
        var valX  = _cx + 20;

        // BAT
        var batColor = (battery < 20) ? Graphics.COLOR_RED : Graphics.COLOR_GREEN;
        _drawMetaRow(dc, labX, valX, rowY,          "BAT",    battery.format("%d") + "%",        batColor);

        // BARO
        var pres = meta.get("pres_pa");
        var presStr = (pres != null) ? _viewModel.formatPressure(pres as Number) : "---";
        _drawMetaRow(dc, labX, valX, rowY + rowDy,  "BARO",   presStr, Graphics.COLOR_WHITE);

        // TEMP
        var temp = meta.get("temp_c");
        var tempStr = (temp != null) ? (temp as Float).format("%.1f") + " \u00B0C" : "---";
        _drawMetaRow(dc, labX, valX, rowY + rowDy*2, "TEMP",  tempStr, Graphics.COLOR_WHITE);

        // STRESS
        var stress = meta.get("stress");
        var stressStr = (stress != null) ? stress.toString() : "---";
        var stressColor = (stress != null && (stress as Number) > 60)
                          ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE;
        _drawMetaRow(dc, labX, valX, rowY + rowDy*3, "STRESS", stressStr, stressColor);

        // SPO2
        var spo2 = meta.get("spo2");
        var spo2Str = (spo2 != null) ? spo2.toString() + "%" : "---";
        var spo2Color = (spo2 != null && (spo2 as Number) < 95)
                        ? Graphics.COLOR_ORANGE : Graphics.COLOR_GREEN;
        _drawMetaRow(dc, labX, valX, rowY + rowDy*4, "SPO2", spo2Str, spo2Color);

        // Overall quality (derived from all sensors)
        var q = _viewModel.computeOverallQuality(status);
        _drawQuality(dc, q);
    }

    private function _drawMetaRow(
        dc     as Graphics.Dc,
        labX   as Number,
        valX   as Number,
        y      as Number,
        label  as String,
        value  as String,
        color  as Number
    ) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(labX, y, Graphics.FONT_TINY, label, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(valX, y, Graphics.FONT_TINY, value, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // ══════════════════════════════════════════════════════════════
    // Screen 6 — Recording stats
    // ══════════════════════════════════════════════════════════════
    private function _drawRecording(dc as Graphics.Dc, status as Dictionary) as Void {
        var state   = status.get("state") as Number;
        var isRec   = (state == SessionManager.STATE_RECORDING);
        var elapsed = status.get("elapsedMs") as Number;
        var packets = status.get("packetCount") as Number;
        var errors  = status.get("errorCount") as Number;
        var fileB   = status.get("estimatedFileSizeBytes") as Number;

        // Recording indicator dot
        if (isRec) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(_cx - 70, _h / 8 + 8, 6);
        }

        // Title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx - 50, _h / 8, Graphics.FONT_SMALL,
                    isRec ? "ENREGISTREMENT" : "ARRÊTÉ",
                    Graphics.TEXT_JUSTIFY_LEFT);

        // Elapsed
        dc.drawText(_cx, _h / 4 + 5, Graphics.FONT_NUMBER_HOT,
                    _viewModel.formatDuration(elapsed),
                    Graphics.TEXT_JUSTIFY_CENTER);

        // Stats rows
        var rowY  = _cy + 5;
        var rowDy = 38;
        var labX  = _cx - 80;
        var valX  = _cx + 20;

        // Packets
        _drawMetaRow(dc, labX, valX, rowY,
                     "PAQUETS", packets.format("%d"), Graphics.COLOR_WHITE);
        // Errors / losses
        var lostPct = (packets > 0) ? (errors * 100 / packets) : 0;
        var lossColor = (lostPct > 2) ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE;
        _drawMetaRow(dc, labX, valX, rowY + rowDy,
                     "PERDUS",
                     errors.format("%d") + "  (" + lostPct.format("%d") + "%)",
                     lossColor);
        // File size
        _drawMetaRow(dc, labX, valX, rowY + rowDy * 2,
                     "TAILLE",
                     _viewModel.formatFileSize(fileB),
                     Graphics.COLOR_WHITE);

        var q = _viewModel.computeOverallQuality(status);
        _drawQuality(dc, q);
    }

    // ══════════════════════════════════════════════════════════════
    // Capture menu overlay
    // ══════════════════════════════════════════════════════════════
    private function _drawMenu(dc as Graphics.Dc, status as Dictionary) as Void {
        // Dim background
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.fillRectangle(0, 0, _w, _h);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 8, Graphics.FONT_SMALL,
                    "MENU CAPTURE", Graphics.TEXT_JUSTIFY_CENTER);

        var items = ["Nouvelle session",
                     "Infos système",
                     "Capteurs actifs",
                     "Fermer"] as Array<String>;

        var selIdx = _uiState.getMenuIndex();
        var itemY  = _h / 4;
        var itemDy = 48;

        for (var i = 0; i < items.size(); i++) {
            var isSelected = (i == selIdx);
            var fg = isSelected ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
            var bg = isSelected ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;
            if (isSelected) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(_cx - 100, itemY + i * itemDy - 2, 200, 30);
            }
            dc.setColor(fg, bg);
            dc.drawText(_cx, itemY + i * itemDy, Graphics.FONT_SMALL,
                        items[i] as String, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // ══════════════════════════════════════════════════════════════
    // Common helpers
    // ══════════════════════════════════════════════════════════════

    //! Draw navigation dots at the bottom of the screen.
    private function _drawNavDots(dc as Graphics.Dc) as Void {
        var n       = UiState.SCREEN_COUNT;
        var radius  = 4;
        var gap     = 14;
        var total   = n * gap;
        var startX  = _cx - total / 2 + radius;
        var dotY    = _h - 18;
        var current = _uiState.getScreenIndex();

        for (var i = 0; i < n; i++) {
            var x = startX + i * gap;
            if (i == current) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(x, dotY, radius);
            } else {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawCircle(x, dotY, radius);
            }
        }
    }

    //! Draw the quality score "Q XX%" above the nav dots.
    private function _drawQuality(dc as Graphics.Dc, q as Number) as Void {
        dc.setColor(_viewModel.qualityColor(q), Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h - 48, Graphics.FONT_TINY,
                    "Q " + q.format("%d") + "%",
                    Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Show padlock when button lock is active.
    private function _drawButtonLockIndicator(dc as Graphics.Dc) as Void {
        if (_uiState.isButtonLocked()) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_w - 20, 20, Graphics.FONT_XTINY,
                        "LOCK", Graphics.TEXT_JUSTIFY_RIGHT);
        }
    }

    //! Draw a compact label + value pair with a coloured value.
    private function _drawLabelValue(
        dc    as Graphics.Dc,
        x     as Number,
        y     as Number,
        label as String,
        value as String,
        color as Number
    ) as Void {
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, Graphics.FONT_TINY, label, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + 80, y, Graphics.FONT_TINY, value, Graphics.TEXT_JUSTIFY_LEFT);
    }

    //! Draw a bar sparkline centred at (cx, cy).
    //! Bars represent successive values from the array (left = oldest).
    private function _drawSparkline(
        dc     as Graphics.Dc,
        values as Array,
        cx     as Number,
        cy     as Number,
        color  as Number
    ) as Void {
        var n = values.size();
        if (n == 0) { return; }

        // Find max absolute value for normalisation
        var maxAbs = 0.01f;
        for (var i = 0; i < n; i++) {
            var v = values[i] as Float;
            var a = (v < 0.0f) ? -v : v;
            if (a > maxAbs) { maxAbs = a; }
        }

        var barW   = 5;
        var barGap = 1;
        var maxH   = 22;
        var total  = n * (barW + barGap);
        var startX = cx - total / 2;

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < n; i++) {
            var v = values[i] as Float;
            var a = (v < 0.0f) ? -v : v;
            var h = ((a / maxAbs) * maxH).toNumber();
            if (h < 2)   { h = 2; }
            if (h > maxH){ h = maxH; }
            var bx = startX + i * (barW + barGap);
            dc.fillRectangle(bx, cy - h, barW, h);
        }
    }

    //! Draw a simple min-normalised line graph centred at (cx, cy).
    //! w = half-width, h = half-height of the graph area.
    private function _drawMiniLineGraph(
        dc     as Graphics.Dc,
        values as Array,
        cx     as Number,
        cy     as Number,
        w      as Number,
        h      as Number,
        color  as Number
    ) as Void {
        var n = values.size();
        if (n < 2) { return; }

        // Find range
        var minV = values[0] as Float;
        var maxV = values[0] as Float;
        for (var i = 1; i < n; i++) {
            var v = values[i] as Float;
            if (v < minV) { minV = v; }
            if (v > maxV) { maxV = v; }
        }
        var range = maxV - minV;
        if (range < 1.0f) { range = 1.0f; }

        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var prevX = 0;
        var prevY = 0;
        for (var i = 0; i < n; i++) {
            var v  = values[i] as Float;
            var px = cx - w + (i * 2 * w / (n - 1));
            var py = cy + h - (((v - minV) / range) * 2.0f * h).toNumber();
            if (i > 0) {
                dc.drawLine(prevX, prevY, px, py);
            }
            prevX = px;
            prevY = py;
        }
    }
}
