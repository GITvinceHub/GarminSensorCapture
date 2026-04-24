import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;

//! Main view — 14-screen UI for GarminSensorCapture.
//! Target: fēnix 8 Pro 454×454 AMOLED.
//! UP = next screen (circular). DOWN = next sub-page (4 per screen).
class MainView extends WatchUi.View {

    private var _sessionManager as SessionManager;
    private var _viewModel      as ViewModel;
    private var _uiState        as UiState;
    private var _w  as Number;
    private var _h  as Number;
    private var _cx as Number;
    private var _cy as Number;

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

        try {
            if (_uiState.isMenuOpen()) {
                _drawMenu(dc, status);
            } else {
                var screen = _uiState.getScreenIndex();
                if      (screen == UiState.SCREEN_SUMMARY)   { _drawSummary(dc, status); }
                else if (screen == UiState.SCREEN_IMU)       { _drawImu(dc, status); }
                else if (screen == UiState.SCREEN_GPS)       { _drawGps(dc, status); }
                else if (screen == UiState.SCREEN_HR)        { _drawHr(dc, status); }
                else if (screen == UiState.SCREEN_META)      { _drawMeta(dc, status); }
                else if (screen == UiState.SCREEN_RECORDING) { _drawRecording(dc, status); }
                else if (screen == UiState.SCREEN_BLE)       { _drawBle(dc, status); }
                else if (screen == UiState.SCREEN_STORAGE)   { _drawStorage(dc, status); }
                else if (screen == UiState.SCREEN_FILESIZE)  { _drawFileSize(dc, status); }
                else if (screen == UiState.SCREEN_BUFFER)    { _drawBuffer(dc, status); }
                else if (screen == UiState.SCREEN_INTEGRITY) { _drawIntegrity(dc, status); }
                else if (screen == UiState.SCREEN_SYNCTIME)  { _drawSyncTime(dc, status); }
                else if (screen == UiState.SCREEN_POWER)     { _drawPower(dc, status); }
                else                                          { _drawPipeline(dc, status); }
                _drawNavDots(dc);
            }
        } catch (ex instanceof Lang.Exception) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy - 20, Graphics.FONT_SMALL, "ERREUR", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy + 10, Graphics.FONT_XTINY, ex.getErrorMessage(), Graphics.TEXT_JUSTIFY_CENTER);
        }

        if (_uiState.isButtonLocked()) { _drawLockIndicator(dc); }
    }

    // ── Screen 0 — RÉSUMÉ ────────────────────────────────────────

    private function _drawSummary(dc as Graphics.Dc, status as Dictionary) as Void {
        var page  = _uiState.getDetailIndex();
        var isRec = (status.get("state") as Number) == SessionManager.STATE_RECORDING;
        var q     = _viewModel.computeOverallQuality(status);

        if (page == 0) {
            _drawTitle(dc, "RÉSUMÉ", isRec ? Graphics.COLOR_RED : Graphics.COLOR_GREEN);
            _drawRecDot(dc, isRec);

            var elapsed    = status.get("elapsedMs");
            var elapsedNum = (elapsed != null) ? elapsed as Number : 0;
            dc.setColor(isRec ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h / 4 - 20, Graphics.FONT_NUMBER_HOT,
                _viewModel.formatDuration(elapsedNum), Graphics.TEXT_JUSTIFY_CENTER);

            var imuFreq = status.get("imuFreqHz");
            var hasGps  = status.get("hasGpsFix");
            var lastHr  = status.get("lastHr");
            var imuStr  = (imuFreq != null) ? (imuFreq as Float).format("%.0f") + " Hz" : "-- Hz";
            var gpsStr  = (hasGps == true) ? "1 Hz" : "NO FIX";
            var hrNum   = (lastHr != null) ? lastHr as Number : 0;
            var hrStr   = (hrNum > 0) ? hrNum.toString() + " bpm" : "-- bpm";

            var ry = _h / 2 - 36;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx - 10, ry,      Graphics.FONT_SMALL, "IMU", Graphics.TEXT_JUSTIFY_RIGHT);
            dc.drawText(_cx - 10, ry + 36, Graphics.FONT_SMALL, "GPS", Graphics.TEXT_JUSTIFY_RIGHT);
            dc.drawText(_cx - 10, ry + 72, Graphics.FONT_SMALL, "FC",  Graphics.TEXT_JUSTIFY_RIGHT);
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx + 10, ry, Graphics.FONT_SMALL, imuStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor((hasGps == true) ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx + 10, ry + 36, Graphics.FONT_SMALL, gpsStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.setColor((hrNum > 0) ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx + 10, ry + 72, Graphics.FONT_SMALL, hrStr, Graphics.TEXT_JUSTIFY_LEFT);

            // Status bar
            var isLinked = (status.get("isLinked") == true);
            var bat      = status.get("battery");
            var batStr   = (bat != null) ? (bat as Number).toString() + "%" : "--%";
            var barY     = _h * 3 / 4 + 10;
            dc.setColor(isLinked ? Graphics.COLOR_BLUE : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx - 95, barY, Graphics.FONT_XTINY,
                isLinked ? "BLE \u25CF" : "BLE \u25CB", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor((hasGps == true) ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, barY, Graphics.FONT_XTINY,
                (hasGps == true) ? "GPS \u25CF" : "GPS \u25CB", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor((bat != null && (bat as Number) > 20) ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx + 95, barY, Graphics.FONT_XTINY, batStr, Graphics.TEXT_JUSTIFY_CENTER);

        } else if (page == 1) {
            _drawTitle(dc, "CONNEXIONS", Graphics.COLOR_WHITE);
            var isLinked = (status.get("isLinked") == true);
            var qs = status.get("commQueueSize");
            var ps = status.get("commPersistentSize");
            var sf = status.get("commSendFailures");
            var sfNum = (sf != null) ? sf as Number : 0;
            var lbArr = ["BLE", "QUEUE", "PERSIST", "ÉCHECS"] as Array<String>;
            var vlArr = [
                isLinked ? "CONNECTÉ" : "DÉCONNECTÉ",
                (qs != null) ? (qs as Number).toString() : "0",
                (ps != null) ? (ps as Number).toString() : "0",
                sfNum.toString()
            ] as Array<String>;
            var clArr = [
                isLinked ? Graphics.COLOR_GREEN : Graphics.COLOR_RED,
                Graphics.COLOR_WHITE,
                Graphics.COLOR_WHITE,
                sfNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 36, lbArr, vlArr, clArr);

        } else if (page == 2) {
            _drawTitle(dc, "CAPTEURS", Graphics.COLOR_WHITE);
            var imuFreq = status.get("imuFreqHz");
            var hasGps  = status.get("hasGpsFix");
            var lastHr  = status.get("lastHr");
            var hrNum   = (lastHr != null) ? lastHr as Number : 0;
            var lbArr = ["IMU", "GPS", "FC", "SPO2"] as Array<String>;
            var vlArr = [
                (imuFreq != null) ? (imuFreq as Float).format("%.0f") + " Hz" : "-- Hz",
                (hasGps == true) ? "FIX OK" : "NO FIX",
                (hrNum > 0) ? hrNum.toString() + " bpm" : "-- bpm",
                "---"
            ] as Array<String>;
            var clArr = [
                Graphics.COLOR_GREEN,
                (hasGps == true) ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE,
                (hrNum > 0) ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY,
                Graphics.COLOR_DK_GRAY
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 36, lbArr, vlArr, clArr);

        } else {
            _drawTitle(dc, "QUALITÉ", Graphics.COLOR_WHITE);
            var qi = _viewModel.computeImuQuality(status);
            var qg = _viewModel.computeGpsQuality(status);
            var qh = _viewModel.computeHrQuality(status);
            var qb = _viewModel.computeBleQuality(status);
            var lbArr = ["IMU", "GPS", "FC", "BLE"] as Array<String>;
            var vlArr = [qi.toString() + "%", qg.toString() + "%", qh.toString() + "%", qb.toString() + "%"] as Array<String>;
            var clArr = [
                _viewModel.qualityColor(qi),
                _viewModel.qualityColor(qg),
                _viewModel.qualityColor(qh),
                _viewModel.qualityColor(qb)
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 36, lbArr, vlArr, clArr);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 1 — IMU ───────────────────────────────────────────

    private function _drawImu(dc as Graphics.Dc, status as Dictionary) as Void {
        var page = _uiState.getDetailIndex();
        var q    = _viewModel.computeImuQuality(status);
        _drawTitle(dc, "IMU", Graphics.COLOR_WHITE);

        if (page == 0) {
            var imuFreq = status.get("imuFreqHz");
            var freqStr = (imuFreq != null) ? (imuFreq as Float).format("%.1f") + " Hz" : "-- Hz";
            var lbArr = ["ACC", "GYRO", "MAG"] as Array<String>;
            var vlArr = [freqStr, freqStr, "25.0 Hz"] as Array<String>;
            var clArr = [Graphics.COLOR_GREEN, Graphics.COLOR_BLUE, Graphics.COLOR_ORANGE] as Array<Number>;
            _drawRows(dc, _h / 4, 40, lbArr, vlArr, clArr);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h * 3 / 4 + 10, Graphics.FONT_XTINY, "DOWN: détails capteur", Graphics.TEXT_JUSTIFY_CENTER);

        } else {
            var axisName = "ax";
            var subTitle = "ACC";
            var subClr   = Graphics.COLOR_GREEN;
            if (page == 2) { axisName = "gx"; subTitle = "GYRO"; subClr = Graphics.COLOR_BLUE; }
            if (page == 3) { axisName = "mx"; subTitle = "MAG";  subClr = Graphics.COLOR_ORANGE; }

            dc.setColor(subClr, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h / 10 + 22, Graphics.FONT_XTINY, subTitle, Graphics.TEXT_JUSTIFY_CENTER);

            var rmsStr = "---"; var maxStr = "---"; var minStr = "---";
            var sensor = _sessionManager.getSensorManager();
            if (sensor != null) {
                var stats = (sensor as SensorManager).getAxisStats(axisName, 100);
                if (stats != null) {
                    var sd  = stats as Dictionary;
                    var rms = sd.get("rms");
                    var mx  = sd.get("max");
                    var mn  = sd.get("min");
                    if (rms != null) { rmsStr = (rms as Float).format("%.3f"); }
                    if (mx  != null) { maxStr = (mx  as Float).format("%.3f"); }
                    if (mn  != null) { minStr = (mn  as Float).format("%.3f"); }
                }
            }
            var lbArr = ["RMS", "MAX", "MIN"] as Array<String>;
            var vlArr = [rmsStr, maxStr, minStr] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 4, 40, lbArr, vlArr, clArr);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 2 — GPS ───────────────────────────────────────────

    private function _drawGps(dc as Graphics.Dc, status as Dictionary) as Void {
        var page   = _uiState.getDetailIndex();
        var q      = _viewModel.computeGpsQuality(status);
        var hasGps = (status.get("hasGpsFix") == true);
        _drawTitle(dc, hasGps ? "GPS 3D" : "GPS NO FIX",
            hasGps ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE);

        if (!hasGps) {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, "En attente...", Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            var snap = {} as Dictionary;
            var pm = _sessionManager.getPositionManager();
            if (pm != null) {
                var s = (pm as PositionManager).getUiSnapshot();
                if (s != null) { snap = s as Dictionary; }
            }
            var lat = snap.get("lat");
            var lon = snap.get("lon");
            var alt = snap.get("alt");
            var spd = snap.get("spd");
            var hdg = snap.get("hdg");
            var acc = snap.get("acc");

            if (page == 0) {
                var lbArr = ["LAT", "LON", "ALT", "VIT", "CAP"] as Array<String>;
                var vlArr = [
                    (lat != null) ? _viewModel.formatCoord(lat as Double) : "---",
                    (lon != null) ? _viewModel.formatCoord(lon as Double) : "---",
                    (alt != null) ? (alt as Float).format("%.0f") + " m" : "---",
                    (spd != null) ? _viewModel.formatSpeed(spd as Float) : "---",
                    (hdg != null) ? _viewModel.formatHeading(hdg as Float) : "---"
                ] as Array<String>;
                var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE, Graphics.COLOR_WHITE,
                             Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
                _drawRows(dc, _h / 4, 30, lbArr, vlArr, clArr);

            } else if (page == 1) {
                var lbArr = ["LAT", "LON"] as Array<String>;
                var vlArr = [
                    (lat != null) ? _viewModel.formatCoord(lat as Double) : "---",
                    (lon != null) ? _viewModel.formatCoord(lon as Double) : "---"
                ] as Array<String>;
                var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
                _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);

            } else if (page == 2) {
                var lbArr = ["VIT", "CAP", "ALT"] as Array<String>;
                var vlArr = [
                    (spd != null) ? _viewModel.formatSpeed(spd as Float) : "---",
                    (hdg != null) ? _viewModel.formatHeading(hdg as Float) : "---",
                    (alt != null) ? (alt as Float).format("%.0f") + " m" : "---"
                ] as Array<String>;
                var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
                _drawRows(dc, _h / 4, 40, lbArr, vlArr, clArr);

            } else {
                var lbArr = ["PRÉCISION", "QUALITÉ"] as Array<String>;
                var vlArr = [
                    (acc != null) ? (acc as Float).format("%.1f") + " m" : "---",
                    q.toString() + "%"
                ] as Array<String>;
                var clArr = [Graphics.COLOR_WHITE, _viewModel.qualityColor(q)] as Array<Number>;
                _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);
            }
        }
        _drawQuality(dc, q);
    }

    // ── Screen 3 — FC ────────────────────────────────────────────

    private function _drawHr(dc as Graphics.Dc, status as Dictionary) as Void {
        var page  = _uiState.getDetailIndex();
        var q     = _viewModel.computeHrQuality(status);
        var lastHr = status.get("lastHr");
        var hrNum  = (lastHr != null) ? lastHr as Number : 0;
        var hasRr  = (status.get("hasRrIntervals") == true);
        _drawTitle(dc, "FC", Graphics.COLOR_RED);

        if (page == 0) {
            var hrClr = (hrNum > 0) ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY;
            dc.setColor(hrClr, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h / 4 - 10, Graphics.FONT_NUMBER_HOT,
                (hrNum > 0) ? hrNum.toString() : "--", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h / 4 + 80, Graphics.FONT_SMALL, "bpm", Graphics.TEXT_JUSTIFY_CENTER);

            var lbArr = ["HRV", "RR"] as Array<String>;
            var vlArr = ["---", hasRr ? "OUI" : "NON"] as Array<String>;
            var clArr = [Graphics.COLOR_DK_GRAY, hasRr ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY] as Array<Number>;
            _drawRows(dc, _h * 3 / 4 - 30, 28, lbArr, vlArr, clArr);

        } else if (page == 1) {
            var lbArr = ["FC", "RR", "SPO2"] as Array<String>;
            var vlArr = [
                (hrNum > 0) ? hrNum.toString() + " bpm" : "-- bpm",
                hasRr ? "OUI" : "NON",
                "---"
            ] as Array<String>;
            var clArr = [
                (hrNum > 0) ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY,
                hasRr ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY,
                Graphics.COLOR_DK_GRAY
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 40, lbArr, vlArr, clArr);

        } else if (page == 2) {
            _drawTitle(dc, "INTERVALLES RR", Graphics.COLOR_WHITE);
            dc.setColor(hasRr ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL,
                hasRr ? "Données RR disponibles" : "Pas de données RR",
                Graphics.TEXT_JUSTIFY_CENTER);

        } else {
            _drawTitle(dc, "HRV / SIGNAL", Graphics.COLOR_WHITE);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, "---", Graphics.TEXT_JUSTIFY_CENTER);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 4 — MÉTADONNÉES ───────────────────────────────────

    private function _drawMeta(dc as Graphics.Dc, status as Dictionary) as Void {
        var page = _uiState.getDetailIndex();
        var q    = _viewModel.computeOverallQuality(status);
        var meta = {} as Dictionary;
        var sensor = _sessionManager.getSensorManager();
        if (sensor != null) {
            var m = (sensor as SensorManager).getMetaSummary();
            if (m != null) { meta = m as Dictionary; }
        }
        var bat = status.get("battery");

        if (page == 0) {
            _drawTitle(dc, "MÉTADONNÉES", Graphics.COLOR_WHITE);
            var baro = meta.get("pressure");
            var temp = meta.get("temp");
            var batNum = (bat != null) ? bat as Number : 0;
            var lbArr = ["BAT", "BARO", "TEMP", "STRESS", "SPO2"] as Array<String>;
            var vlArr = [
                (bat != null) ? batNum.toString() + "%" : "---",
                (baro != null) ? _viewModel.formatPressure(baro as Number) : "---",
                (temp != null) ? (temp as Float).format("%.1f") + " \u00B0C" : "---",
                "---", "---"
            ] as Array<String>;
            var clArr = [
                batNum > 20 ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE,
                Graphics.COLOR_WHITE, Graphics.COLOR_WHITE,
                Graphics.COLOR_DK_GRAY, Graphics.COLOR_DK_GRAY
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 30, lbArr, vlArr, clArr);

        } else if (page == 1) {
            _drawTitle(dc, "BAT / SYSTÈME", Graphics.COLOR_WHITE);
            var batNum = (bat != null) ? bat as Number : 0;
            var lbArr = ["BATTERIE", "ÉTAT"] as Array<String>;
            var vlArr = [(bat != null) ? batNum.toString() + "%" : "---", "NORMAL"] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_GREEN] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);

        } else if (page == 2) {
            _drawTitle(dc, "BARO / ALTITUDE", Graphics.COLOR_WHITE);
            var baro = meta.get("pressure");
            var alt  = meta.get("elev");
            var lbArr = ["PRESSION", "ALTITUDE"] as Array<String>;
            var vlArr = [
                (baro != null) ? _viewModel.formatPressure(baro as Number) : "---",
                (alt  != null) ? (alt as Float).format("%.0f") + " m" : "---"
            ] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);

        } else {
            _drawTitle(dc, "STRESS / SPO2", Graphics.COLOR_WHITE);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, "--- / ---", Graphics.TEXT_JUSTIFY_CENTER);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 5 — ENREGISTREMENT ────────────────────────────────

    private function _drawRecording(dc as Graphics.Dc, status as Dictionary) as Void {
        var page    = _uiState.getDetailIndex();
        var q       = _viewModel.computeIntegrityQuality(status);
        var isRec   = (status.get("state") as Number) == SessionManager.STATE_RECORDING;
        var elapsed = status.get("elapsedMs");
        var elapsedNum = (elapsed != null) ? elapsed as Number : 0;
        _drawRecDot(dc, isRec);

        if (page == 0) {
            _drawTitle(dc, isRec ? "ENREGISTREMENT" : "ARRÊTÉ",
                isRec ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY);
            dc.setColor(isRec ? Graphics.COLOR_RED : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h / 4 - 10, Graphics.FONT_NUMBER_HOT,
                _viewModel.formatDuration(elapsedNum), Graphics.TEXT_JUSTIFY_CENTER);

            var pkt  = status.get("packetCount");
            var errs = status.get("errorCount");
            var fsz  = status.get("estimatedFileSizeBytes");
            var errNum = (errs != null) ? errs as Number : 0;
            var lbArr = ["PAQUETS", "PERDUS", "TAILLE"] as Array<String>;
            var vlArr = [
                (pkt != null) ? (pkt as Number).toString() : "0",
                errNum.toString(),
                (fsz != null) ? _viewModel.formatFileSize(fsz as Number) : "0 B"
            ] as Array<String>;
            var clArr = [
                Graphics.COLOR_WHITE,
                errNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE,
                Graphics.COLOR_WHITE
            ] as Array<Number>;
            _drawRows(dc, _h * 3 / 4 - 60, 30, lbArr, vlArr, clArr);

        } else if (page == 1) {
            _drawTitle(dc, "PAQUETS", Graphics.COLOR_WHITE);
            var pkt     = status.get("packetCount");
            var batches = status.get("batchesSent");
            var lbArr = ["TOTAL", "BATCHS"] as Array<String>;
            var vlArr = [
                (pkt     != null) ? (pkt     as Number).toString() : "0",
                (batches != null) ? (batches as Number).toString() : "0"
            ] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);

        } else if (page == 2) {
            _drawTitle(dc, "PERTES", Graphics.COLOR_WHITE);
            var errs    = status.get("errorCount");
            var dropped = status.get("droppedSamples");
            var errNum  = (errs    != null) ? errs    as Number : 0;
            var dropNum = (dropped != null) ? dropped as Number : 0;
            var lbArr = ["ERREURS", "ÉCHANT. PERDUS"] as Array<String>;
            var vlArr = [errNum.toString(), dropNum.toString()] as Array<String>;
            var clArr = [
                errNum  > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE,
                dropNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE
            ] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);

        } else {
            _drawTitle(dc, "TAILLE / DÉBIT", Graphics.COLOR_WHITE);
            var fsz = status.get("estimatedFileSizeBytes");
            var rateStr = "---";
            if (fsz != null && elapsedNum > 0) {
                var elapsedS = elapsedNum / 1000;
                if (elapsedS > 0) {
                    var kbps = (fsz as Number) / 1024 / elapsedS;
                    rateStr = kbps.toString() + " KB/s";
                }
            }
            var lbArr = ["TAILLE", "DÉBIT"] as Array<String>;
            var vlArr = [
                (fsz != null) ? _viewModel.formatFileSize(fsz as Number) : "0 B",
                rateStr
            ] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 6 — LIEN BLE ──────────────────────────────────────

    private function _drawBle(dc as Graphics.Dc, status as Dictionary) as Void {
        var page     = _uiState.getDetailIndex();
        var q        = _viewModel.computeBleQuality(status);
        var isLinked = (status.get("isLinked") == true);
        _drawTitle(dc, "LIEN BLE", Graphics.COLOR_BLUE);

        if (page == 0) {
            dc.setColor(isLinked ? Graphics.COLOR_GREEN : Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h / 4, Graphics.FONT_SMALL,
                isLinked ? "CONNECTÉ" : "DÉCONNECTÉ", Graphics.TEXT_JUSTIFY_CENTER);

            var qs  = status.get("commQueueSize");
            var sf  = status.get("commSendFailures");
            var pkt = status.get("packetCount");
            var elapsed = status.get("elapsedMs");
            var sfNum   = (sf != null) ? sf as Number : 0;
            var rateStr = "---";
            if (pkt != null && elapsed != null) {
                var elapsedS = (elapsed as Number) / 1000;
                if (elapsedS > 0) {
                    var ppsF = (pkt as Number).toFloat() / elapsedS.toFloat();
                    rateStr = ppsF.format("%.1f") + " pkt/s";
                }
            }
            var lbArr = ["DÉBIT", "QUEUE", "RETRY", "ÉCHECS"] as Array<String>;
            var vlArr = [
                rateStr,
                (qs != null) ? (qs as Number).toString() : "0",
                "---",
                sfNum.toString()
            ] as Array<String>;
            var clArr = [
                Graphics.COLOR_WHITE, Graphics.COLOR_WHITE,
                Graphics.COLOR_DK_GRAY,
                sfNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE
            ] as Array<Number>;
            _drawRows(dc, _h / 2 - 36, 30, lbArr, vlArr, clArr);

        } else if (page == 1) {
            _drawTitle(dc, "LATENCE", Graphics.COLOR_WHITE);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, "---", Graphics.TEXT_JUSTIFY_CENTER);

        } else if (page == 2) {
            _drawTitle(dc, "DÉBIT INST.", Graphics.COLOR_WHITE);
            var pkt = status.get("packetCount");
            var elapsed = status.get("elapsedMs");
            var rateStr = "---";
            if (pkt != null && elapsed != null) {
                var elapsedS = (elapsed as Number) / 1000;
                if (elapsedS > 0) {
                    var ppsF = (pkt as Number).toFloat() / elapsedS.toFloat();
                    rateStr = ppsF.format("%.2f") + " pkt/s";
                }
            }
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, rateStr, Graphics.TEXT_JUSTIFY_CENTER);

        } else {
            _drawTitle(dc, "QUEUE PERSIST.", Graphics.COLOR_WHITE);
            var ps = status.get("commPersistentSize");
            var sf = status.get("commSendFailures");
            var lbArr = ["EN ATTENTE ACK", "ÉCHECS TOTAL"] as Array<String>;
            var vlArr = [
                (ps != null) ? (ps as Number).toString() : "0",
                (sf != null) ? (sf as Number).toString() : "0"
            ] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 7 — STOCKAGE TEL ──────────────────────────────────

    private function _drawStorage(dc as Graphics.Dc, status as Dictionary) as Void {
        var page     = _uiState.getDetailIndex();
        var isLinked = (status.get("isLinked") == true);
        var q        = isLinked ? 100 : 50;
        _drawTitle(dc, "STOCKAGE TEL", Graphics.COLOR_WHITE);

        if (page == 0) {
            var lbArr = ["LIBRE", "TOTAL", "UTILISÉ", "ÉCRITURE"] as Array<String>;
            var vlArr = ["---", "---", "---", isLinked ? "EN COURS" : "HORS LIGNE"] as Array<String>;
            var clArr = [
                Graphics.COLOR_DK_GRAY, Graphics.COLOR_DK_GRAY, Graphics.COLOR_DK_GRAY,
                isLinked ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 36, lbArr, vlArr, clArr);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, "Données Android\nnon disponibles",
                Graphics.TEXT_JUSTIFY_CENTER);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 8 — FICHIER ───────────────────────────────────────

    private function _drawFileSize(dc as Graphics.Dc, status as Dictionary) as Void {
        var page    = _uiState.getDetailIndex();
        var isRec   = (status.get("state") as Number) == SessionManager.STATE_RECORDING;
        var q       = isRec ? 95 : 100;
        var fsz     = status.get("estimatedFileSizeBytes");
        var elapsed = status.get("elapsedMs");
        _drawTitle(dc, "FICHIER", Graphics.COLOR_WHITE);

        if (page == 0) {
            var pkt = status.get("packetCount");
            var rateStr = "---"; var estStr = "---";
            if (fsz != null && elapsed != null) {
                var elapsedS = (elapsed as Number) / 1000;
                if (elapsedS > 0) {
                    var kbF     = (fsz as Number).toFloat() / 1024.0f;
                    var kbpsF   = kbF / elapsedS.toFloat();
                    rateStr     = kbpsF.format("%.2f") + " KB/s";
                    var mbEst2h = kbpsF * 7200.0f / 1024.0f;
                    estStr      = mbEst2h.format("%.0f") + " MB";
                }
            }
            var lbArr = ["TAILLE", "PAQUETS", "DÉBIT", "EST 2H"] as Array<String>;
            var vlArr = [
                (fsz != null) ? _viewModel.formatFileSize(fsz as Number) : "0 B",
                (pkt != null) ? (pkt as Number).toString() : "0",
                rateStr, estStr
            ] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE,
                         Graphics.COLOR_WHITE, Graphics.COLOR_DK_GRAY] as Array<Number>;
            _drawRows(dc, _h / 4, 32, lbArr, vlArr, clArr);

        } else if (page == 1) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_NUMBER_HOT,
                (fsz != null) ? _viewModel.formatFileSize(fsz as Number) : "0 B",
                Graphics.TEXT_JUSTIFY_CENTER);

        } else if (page == 2) {
            _drawTitle(dc, "PROJECTIONS", Graphics.COLOR_WHITE);
            var proj1h = "---"; var proj2h = "---"; var proj4h = "---"; var growStr = "---";
            if (fsz != null && elapsed != null) {
                var elapsedS = (elapsed as Number) / 1000;
                if (elapsedS > 0) {
                    var kbpsF = (fsz as Number).toFloat() / 1024.0f / elapsedS.toFloat();
                    growStr  = (kbpsF * 60.0f).format("%.0f") + " KB/min";
                    proj1h   = (kbpsF * 3600.0f / 1024.0f).format("%.0f") + " MB";
                    proj2h   = (kbpsF * 7200.0f / 1024.0f).format("%.0f") + " MB";
                    proj4h   = (kbpsF * 14400.0f / 1024.0f).format("%.0f") + " MB";
                }
            }
            var lbArr = ["CROISSANCE", "PROJ 1H", "PROJ 2H", "PROJ 4H"] as Array<String>;
            var vlArr = [growStr, proj1h, proj2h, proj4h] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_DK_GRAY,
                         Graphics.COLOR_DK_GRAY, Graphics.COLOR_DK_GRAY] as Array<Number>;
            _drawRows(dc, _h / 4, 32, lbArr, vlArr, clArr);

        } else {
            var lbArr = ["TAILLE MOY. PKT"] as Array<String>;
            var vlArr = ["900 B"] as Array<String>;
            var clArr = [Graphics.COLOR_DK_GRAY] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 9 — BUFFER ────────────────────────────────────────

    private function _drawBuffer(dc as Graphics.Dc, status as Dictionary) as Void {
        var page    = _uiState.getDetailIndex();
        var q       = _viewModel.computeBufferQuality(status);
        var qs      = status.get("commQueueSize");
        var ps      = status.get("commPersistentSize");
        var dropped = status.get("droppedSamples");
        _drawTitle(dc, "BUFFER", Graphics.COLOR_WHITE);

        if (page == 0) {
            var qsNum      = (qs      != null) ? qs      as Number : 0;
            var droppedNum = (dropped != null) ? dropped as Number : 0;
            var satPct     = qsNum * 100 / 20;
            if (satPct > 100) { satPct = 100; }
            var lbArr = ["QUEUE MEM", "FLUSH", "PERDU", "SATURATION"] as Array<String>;
            var vlArr = [
                qsNum.toString(),
                (ps != null) ? (ps as Number).toString() : "0",
                droppedNum.toString(),
                satPct.toString() + "%"
            ] as Array<String>;
            var clArr = [
                qsNum > 15 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE,
                Graphics.COLOR_WHITE,
                droppedNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE,
                _threshColor(satPct, 70, 90)
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 32, lbArr, vlArr, clArr);
            _drawBar(dc, _cx - 80, _h * 3 / 4 - 10, 160, 8, satPct, _threshColor(satPct, 70, 90));

        } else if (page == 1) {
            _drawTitle(dc, "QUEUE INST.", Graphics.COLOR_WHITE);
            var pressStr = "---";
            var bm = _sessionManager.getBatchManager();
            if (bm != null) {
                pressStr = (bm as BatchManager).getQueuePressure().toString() + "%";
            }
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_NUMBER_HOT, pressStr, Graphics.TEXT_JUSTIFY_CENTER);

        } else if (page == 2) {
            _drawTitle(dc, "ÉCHANT. PERDUS", Graphics.COLOR_WHITE);
            var dropNum = (dropped != null) ? dropped as Number : 0;
            dc.setColor(dropNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_NUMBER_HOT, dropNum.toString(), Graphics.TEXT_JUSTIFY_CENTER);

        } else {
            _drawTitle(dc, "BACKLOG", Graphics.COLOR_WHITE);
            var lbArr = ["MEM QUEUE", "PERSIST"] as Array<String>;
            var vlArr = [
                (qs != null) ? (qs as Number).toString() : "0",
                (ps != null) ? (ps as Number).toString() : "0"
            ] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 10 — INTÉGRITÉ ────────────────────────────────────

    private function _drawIntegrity(dc as Graphics.Dc, status as Dictionary) as Void {
        var page = _uiState.getDetailIndex();
        var q    = _viewModel.computeIntegrityQuality(status);
        _drawTitle(dc, "INTÉGRITÉ", Graphics.COLOR_WHITE);

        if (page == 0) {
            var pkt     = status.get("packetCount");
            var errs    = status.get("errorCount");
            var dropped = status.get("droppedSamples");
            var errNum  = (errs    != null) ? errs    as Number : 0;
            var dropNum = (dropped != null) ? dropped as Number : 0;
            var lbArr = ["PAQUETS", "PERTES", "ERREURS"] as Array<String>;
            var vlArr = [
                (pkt != null) ? (pkt as Number).toString() : "0",
                dropNum.toString(),
                errNum.toString()
            ] as Array<String>;
            var clArr = [
                Graphics.COLOR_WHITE,
                dropNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE,
                errNum  > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 40, lbArr, vlArr, clArr);
            _drawSep(dc, _h / 2 + 50);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h / 2 + 60, Graphics.FONT_XTINY, "SYNC: OK", Graphics.TEXT_JUSTIFY_CENTER);

        } else if (page == 1) {
            _drawTitle(dc, "ERREURS PAR TYPE", Graphics.COLOR_WHITE);
            var errs   = status.get("errorCount");
            var errNum = (errs != null) ? errs as Number : 0;
            dc.setColor(errNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_NUMBER_HOT, errNum.toString(), Graphics.TEXT_JUSTIFY_CENTER);

        } else if (page == 2) {
            _drawTitle(dc, "ANALYSE GAPS", Graphics.COLOR_WHITE);
            var pkt = status.get("packetCount");
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_NUMBER_HOT,
                (pkt != null) ? (pkt as Number).toString() : "0", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy + 50, Graphics.FONT_XTINY, "paquets envoyés", Graphics.TEXT_JUSTIFY_CENTER);

        } else {
            _drawTitle(dc, "FLAGS ERREUR", Graphics.COLOR_WHITE);
            var sf    = status.get("commSendFailures");
            var sfNum = (sf != null) ? sf as Number : 0;
            var lbArr = ["COMM FAILURES"] as Array<String>;
            var vlArr = [sfNum.toString()] as Array<String>;
            var clArr = [sfNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 11 — SYNC TEMPS ───────────────────────────────────

    private function _drawSyncTime(dc as Graphics.Dc, status as Dictionary) as Void {
        var page = _uiState.getDetailIndex();
        _drawTitle(dc, "SYNC TEMPS", Graphics.COLOR_WHITE);
        var clock   = System.getClockTime();
        var timeStr = clock.hour.format("%02d") + ":" + clock.min.format("%02d") + ":" + clock.sec.format("%02d");

        if (page == 0) {
            var lbArr = ["MONTRE", "TÉLÉPHONE", "GPS", "DRIFT"] as Array<String>;
            var vlArr = [timeStr, "---", "---", "---"] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_DK_GRAY,
                         Graphics.COLOR_DK_GRAY, Graphics.COLOR_DK_GRAY] as Array<Number>;
            _drawRows(dc, _h / 4, 36, lbArr, vlArr, clArr);

        } else if (page == 1) {
            _drawTitle(dc, "DRIFT MONTRE/TÉL", Graphics.COLOR_WHITE);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, "---", Graphics.TEXT_JUSTIFY_CENTER);

        } else if (page == 2) {
            _drawTitle(dc, "DRIFT GPS/MONTRE", Graphics.COLOR_WHITE);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, "---", Graphics.TEXT_JUSTIFY_CENTER);

        } else {
            _drawTitle(dc, "ÂGE GPS TIMESTAMP", Graphics.COLOR_WHITE);
            var ageStr = "---";
            var pm = _sessionManager.getPositionManager();
            if (pm != null) {
                var snap = (pm as PositionManager).getUiSnapshot();
                if (snap != null) {
                    var fa = (snap as Dictionary).get("fixAge");
                    if (fa != null) { ageStr = (fa as Number).toString() + " ms"; }
                }
            }
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_SMALL, ageStr, Graphics.TEXT_JUSTIFY_CENTER);
        }
        _drawQuality(dc, 90);
    }

    // ── Screen 12 — AUTONOMIE ────────────────────────────────────

    private function _drawPower(dc as Graphics.Dc, status as Dictionary) as Void {
        var page        = _uiState.getDetailIndex();
        var q           = _viewModel.computePowerQuality(status);
        var bat         = status.get("battery");
        var startBat    = status.get("sessionStartBattery");
        var elapsed     = status.get("elapsedMs");
        var batNum      = (bat     != null) ? bat     as Number : 0;
        var startBatNum = (startBat != null) ? startBat as Number : batNum;
        _drawTitle(dc, "BATTERIE", Graphics.COLOR_WHITE);

        var batClr = Graphics.COLOR_GREEN;
        if (batNum <= 20) { batClr = Graphics.COLOR_ORANGE; }
        if (batNum <= 10) { batClr = Graphics.COLOR_RED; }

        // Compute consumption
        var consStr = "---"; var restStr = "---";
        if (elapsed != null && startBatNum > batNum) {
            var elapsedMs = elapsed as Number;
            if (elapsedMs > 60000) {  // need at least 1 min
                var elapsedHF = elapsedMs.toFloat() / 3600000.0f;
                if (elapsedHF > 0.0f) {
                    var consPerHF = (startBatNum - batNum).toFloat() / elapsedHF;
                    consStr = consPerHF.format("%.1f") + " %/h";
                    if (consPerHF > 0.0f) {
                        restStr = (batNum.toFloat() / consPerHF).format("%.0f") + " h";
                    }
                }
            }
        }

        if (page == 0) {
            dc.setColor(batClr, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _h / 4 - 10, Graphics.FONT_NUMBER_HOT,
                batNum.toString() + "%", Graphics.TEXT_JUSTIFY_CENTER);
            _drawBar(dc, _cx - 80, _h / 4 + 60, 160, 10, batNum, batClr);
            var lbArr = ["RESTANT", "CONS.", "MODE"] as Array<String>;
            var vlArr = [restStr, consStr, "NORMAL"] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE, Graphics.COLOR_WHITE, Graphics.COLOR_DK_GRAY] as Array<Number>;
            _drawRows(dc, _h / 2 + 10, 30, lbArr, vlArr, clArr);

        } else if (page == 1) {
            dc.setColor(batClr, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_NUMBER_HOT, batNum.toString() + "%", Graphics.TEXT_JUSTIFY_CENTER);
            _drawBar(dc, _cx - 80, _cy + 60, 160, 10, batNum, batClr);

        } else if (page == 2) {
            _drawTitle(dc, "CONSOMMATION", Graphics.COLOR_WHITE);
            var lbArr = ["DÉBUT SESSION", "ACTUEL", "CONSOM."] as Array<String>;
            var vlArr = [startBatNum.toString() + "%", batNum.toString() + "%", consStr] as Array<String>;
            var clArr = [Graphics.COLOR_DK_GRAY, Graphics.COLOR_WHITE, Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 4, 40, lbArr, vlArr, clArr);

        } else {
            _drawTitle(dc, "AUTONOMIE RESTANTE", Graphics.COLOR_WHITE);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, _cy, Graphics.FONT_NUMBER_HOT, restStr, Graphics.TEXT_JUSTIFY_CENTER);
        }
        _drawQuality(dc, q);
    }

    // ── Screen 13 — PIPELINE ─────────────────────────────────────

    private function _drawPipeline(dc as Graphics.Dc, status as Dictionary) as Void {
        var page     = _uiState.getDetailIndex();
        var q        = _viewModel.computePipelineQuality(status);
        var isLinked = (status.get("isLinked") == true);
        var isRec    = (status.get("state") as Number) == SessionManager.STATE_RECORDING;

        if (page == 0) {
            _drawTitle(dc, "CAPTURE FLOW", Graphics.COLOR_WHITE);
            var checkY = _h / 4;
            var rowH   = 34;
            dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, checkY, Graphics.FONT_SMALL, "MONTRE  OK", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(isLinked ? Graphics.COLOR_GREEN : Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, checkY + rowH, Graphics.FONT_SMALL,
                isLinked ? "BLE  OK" : "BLE  --", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(isLinked ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, checkY + rowH * 2, Graphics.FONT_SMALL,
                isLinked ? "PHONE  OK" : "PHONE  ?", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(isLinked && isRec ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx, checkY + rowH * 3, Graphics.FONT_SMALL,
                isLinked && isRec ? "WRITE  OK" : "WRITE  --", Graphics.TEXT_JUSTIFY_CENTER);
            _drawSep(dc, checkY + rowH * 4 + 4);
            var pkt     = status.get("packetCount");
            var dropped = status.get("droppedSamples");
            var dropNum = (dropped != null) ? dropped as Number : 0;
            var lbArr = ["PAQUETS", "PERTES"] as Array<String>;
            var vlArr = [
                (pkt != null) ? (pkt as Number).toString() : "0",
                dropNum.toString()
            ] as Array<String>;
            var clArr = [
                Graphics.COLOR_WHITE,
                dropNum > 0 ? Graphics.COLOR_ORANGE : Graphics.COLOR_WHITE
            ] as Array<Number>;
            _drawRows(dc, checkY + rowH * 4 + 10, 28, lbArr, vlArr, clArr);

        } else if (page == 1) {
            _drawTitle(dc, "ÉTAT MONTRE", Graphics.COLOR_WHITE);
            var imuFreq = status.get("imuFreqHz");
            var hasGps  = status.get("hasGpsFix");
            var lastHr  = status.get("lastHr");
            var hrNum   = (lastHr != null) ? lastHr as Number : 0;
            var lbArr = ["IMU", "GPS", "FC"] as Array<String>;
            var vlArr = [
                (imuFreq != null) ? (imuFreq as Float).format("%.0f") + " Hz" : "-- Hz",
                (hasGps == true) ? "FIX OK" : "NO FIX",
                (hrNum > 0) ? hrNum.toString() + " bpm" : "-- bpm"
            ] as Array<String>;
            var clArr = [
                Graphics.COLOR_GREEN,
                (hasGps == true) ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE,
                (hrNum > 0) ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY
            ] as Array<Number>;
            _drawRows(dc, _h / 4, 40, lbArr, vlArr, clArr);

        } else if (page == 2) {
            _drawTitle(dc, "ÉTAT BLE", Graphics.COLOR_WHITE);
            var qs    = status.get("commQueueSize");
            var lbArr = ["LIEN", "QUEUE"] as Array<String>;
            var vlArr = [
                isLinked ? "CONNECTÉ" : "DÉCONNECTÉ",
                (qs != null) ? (qs as Number).toString() : "0"
            ] as Array<String>;
            var clArr = [
                isLinked ? Graphics.COLOR_GREEN : Graphics.COLOR_RED,
                Graphics.COLOR_WHITE
            ] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);

        } else {
            _drawTitle(dc, "ÉTAT STOCKAGE", Graphics.COLOR_WHITE);
            var fsz   = status.get("estimatedFileSizeBytes");
            var lbArr = ["FICHIER EST."] as Array<String>;
            var vlArr = [(fsz != null) ? _viewModel.formatFileSize(fsz as Number) : "0 B"] as Array<String>;
            var clArr = [Graphics.COLOR_WHITE] as Array<Number>;
            _drawRows(dc, _h / 3, 46, lbArr, vlArr, clArr);
        }
        _drawQuality(dc, q);
    }

    // ── Menu overlay ─────────────────────────────────────────────

    private function _drawMenu(dc as Graphics.Dc, status as Dictionary) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(_cx - 120, _cy - 110, 240, 220, 16);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawRoundedRectangle(_cx - 120, _cy - 110, 240, 220, 16);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _cy - 100, Graphics.FONT_SMALL, "MENU", Graphics.TEXT_JUSTIFY_CENTER);
        _drawSep(dc, _cy - 78);

        var items = ["Nouvelle session", "Infos système", "Capteurs actifs", "Fermer"] as Array<String>;
        var menuIdx = _uiState.getMenuIndex();
        var itemY   = _cy - 70;
        var itemH   = 38;
        for (var i = 0; i < UiState.MENU_COUNT; i++) {
            if (i == menuIdx) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillRoundedRectangle(_cx - 100, itemY + i * itemH - 2, 200, 30, 6);
                dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
            } else {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            }
            dc.drawText(_cx, itemY + i * itemH, Graphics.FONT_SMALL,
                items[i] as String, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // ── Shared helpers ────────────────────────────────────────────

    private function _drawTitle(dc as Graphics.Dc, title as String, color as Number) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h / 10, Graphics.FONT_SMALL, title, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function _drawRecDot(dc as Graphics.Dc, isRec as Boolean) as Void {
        if (isRec) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(_cx - 70, _h / 8 + 8, 5);
        }
    }

    //! Centre-split rows: labels right-justified at cx-10, values left at cx+10.
    private function _drawRows(
        dc     as Graphics.Dc,
        startY as Number,
        rowH   as Number,
        labels as Array<String>,
        vals   as Array<String>,
        colors as Array<Number>
    ) as Void {
        for (var i = 0; i < labels.size(); i++) {
            var y = startY + i * rowH;
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx - 10, y, Graphics.FONT_SMALL, labels[i] as String, Graphics.TEXT_JUSTIFY_RIGHT);
            dc.setColor(colors[i] as Number, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_cx + 10, y, Graphics.FONT_SMALL, vals[i] as String, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    private function _drawSep(dc as Graphics.Dc, y as Number) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(_cx - 80, y, _cx + 80, y);
    }

    private function _drawBar(
        dc    as Graphics.Dc,
        x     as Number,
        y     as Number,
        w     as Number,
        h     as Number,
        pct   as Number,
        color as Number
    ) as Void {
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawRectangle(x, y, w, h);
        var fillW = pct * w / 100;
        if (fillW > 0) {
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x, y, fillW, h);
        }
    }

    private function _drawQuality(dc as Graphics.Dc, q as Number) as Void {
        dc.setColor(_viewModel.qualityColor(q), Graphics.COLOR_TRANSPARENT);
        dc.drawText(_cx, _h - 62, Graphics.FONT_TINY, "Q " + q.toString() + "%",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! 14 nav dots, radius=2, gap=13px centre-to-centre, at y=h-20.
    private function _drawNavDots(dc as Graphics.Dc) as Void {
        var screen  = _uiState.getScreenIndex();
        var count   = UiState.SCREEN_COUNT;
        var gap     = 13;
        var startX  = _cx - ((count - 1) * gap) / 2;
        var dotY    = _h - 20;
        for (var i = 0; i < count; i++) {
            var dotX = startX + i * gap;
            if (i == screen) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(dotX, dotY, 2);
            } else {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(dotX, dotY, 1);
            }
        }
    }

    private function _drawLockIndicator(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_w - 10, 10, Graphics.FONT_XTINY, "LOCK", Graphics.TEXT_JUSTIFY_RIGHT);
    }

    //! Returns GREEN / ORANGE / RED based on value vs warn/err thresholds.
    private function _threshColor(v as Number, warn as Number, err as Number) as Number {
        if (v < warn) { return Graphics.COLOR_GREEN; }
        if (v < err)  { return Graphics.COLOR_ORANGE; }
        return Graphics.COLOR_RED;
    }
}
