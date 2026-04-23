# Integration Checklist — GarminSensorCapture v1.0.0

**Document ID:** CL-001  
**Version:** 1.0.0  
**Date:** 2024-04-22

Use this checklist before any release or after significant code changes. Each item must be checked (✓) or marked N/A with justification.

---

## Section 1 — Development Environment

### 1.1 Connect IQ Watch App

- [ ] Connect IQ SDK 6.x installed at expected path
- [ ] `manifest.xml` valid: `fenix8pro` in products list, API level ≥ 3.3.0
- [ ] App compiles without errors in Connect IQ simulator
- [ ] App compiles without errors for physical target (fenix8pro)
- [ ] No unused imports or dead code warnings from SDK
- [ ] `COMPANION_APP_ID` matches the Android `ConnectIQManager` GUID

### 1.2 Android Companion App

- [ ] Project opens without sync errors in Android Studio
- [ ] `app/build.gradle` specifies `minSdk 26`, `targetSdk 34`, `compileSdk 34`
- [ ] `ConnectIQ.aar` present in `libs/` directory
- [ ] All Gradle dependencies resolve (no "unresolved dependency" errors)
- [ ] App compiles in debug mode without errors
- [ ] App compiles in release mode (with ProGuard if enabled) without errors
- [ ] `FileProvider` authority matches `AndroidManifest.xml`

### 1.3 Python Analysis Pipeline

- [ ] Python 3.10+ installed: `python --version`
- [ ] All requirements installed: `pip install -r requirements.txt`
- [ ] `python main.py sample_data/sample_session.jsonl` runs without errors
- [ ] All 6 output files generated in `./output/`
- [ ] pytest installed: `python -m pytest --version`
- [ ] All unit tests pass: `python -m pytest 05_tests/test_python/ -v`

---

## Section 2 — Watch App Functional Tests

### 2.1 Startup and Display

- [ ] App launches on fēnix 8 Pro without crash
- [ ] Initial screen shows "IDLE" status
- [ ] Battery percentage visible in display
- [ ] BLE status shows "CLOSED" when companion not connected

### 2.2 Sensor Initialization

- [ ] Pressing START begins recording session
- [ ] Status changes to "RECORDING"
- [ ] Sample counter increments visibly (approximately 25/second)
- [ ] Displayed frequency stabilizes to 24–26 Hz within 5 seconds
- [ ] GPS fix indicator updates when outdoors (may take 1–15 minutes cold)

### 2.3 BLE Communication

- [ ] With companion app running, BLE status shows "OPEN" within 10s
- [ ] Packet counter increments approximately every 1 second
- [ ] On Android disconnect, watch shows "CLOSED" and attempts reconnect
- [ ] Reconnect succeeds within 60 seconds when Android app is relaunched

### 2.4 Session Termination

- [ ] Short-pressing START stops recording
- [ ] Status returns to "IDLE"
- [ ] No crash or error screen on stop
- [ ] Long-press START during recording marks event (ef bitmask set)

---

## Section 3 — Android App Functional Tests

### 3.1 Startup and Permissions

- [ ] App requests BLUETOOTH_SCAN and BLUETOOTH_CONNECT on first launch (API 31+)
- [ ] App requests location permission if needed by Android version
- [ ] UI shows "SDK: READY" when ConnectIQ initialized
- [ ] UI shows "Watch: CONNECTED" when fēnix 8 Pro is paired and in range

### 3.2 Data Reception

- [ ] Packet counter increments when watch is recording
- [ ] Throughput display shows ~1 packet/second
- [ ] File size display updates as data is written
- [ ] Packet loss % display is ≤ 5% in normal conditions
- [ ] Battery level from watch is displayed

### 3.3 File Operations

- [ ] JSONL file created in app-private storage when session starts
- [ ] JSONL file is valid (each line is a parseable JSON object)
- [ ] Received_at field is present in each JSONL line (added by Android)
- [ ] File rotation occurs correctly if size exceeds 100MB
- [ ] Export button generates a shareable ZIP or JSONL file
- [ ] FileProvider URI works for sharing to other apps

### 3.4 Error Handling

- [ ] App does not crash when watch disconnects mid-session
- [ ] App recovers when watch reconnects (new channel opens)
- [ ] Invalid/malformed packets logged as warnings, not crashes
- [ ] Storage permission denied: graceful error message shown

---

## Section 4 — BLE Protocol Validation

### 4.1 Packet Structure

- [ ] Every received packet has fields: `pv`, `sid`, `pi`, `dtr`, `s`
- [ ] `pv` is always 1
- [ ] `sid` matches format `YYYYMMDD_HHMMSS`
- [ ] `pi` increments monotonically within a session
- [ ] `s` array length is 1–25 samples
- [ ] Each sample has fields: `t`, `ax`, `ay`, `az`, `gx`, `gy`, `gz`

### 4.2 GPS Data

- [ ] GPS fix present in packets when watch has satellite lock
- [ ] `lat` in range [-90, 90], `lon` in range [-180, 180]
- [ ] `ts` is a Unix timestamp in seconds (10-digit number)
- [ ] `alt_m` is a reasonable value (not 0 or extreme outlier)

### 4.3 Gap Detection

- [ ] `pi` gaps are detected by GarminReceiver
- [ ] Packet loss percentage calculated correctly
- [ ] Android UI displays gap count when gaps occur

---

## Section 5 — Python Pipeline End-to-End

### 5.1 Parser

- [ ] Sample JSONL file parsed without errors
- [ ] All 10 packets from sample file returned
- [ ] Invalid JSON lines in mixed file are skipped
- [ ] `get_session_ids()` returns unique sessions in order
- [ ] `filter_by_session()` returns only matching packets

### 5.2 Normalizer

- [ ] IMU DataFrame has 250 rows (10 packets × 25 samples)
- [ ] GPS DataFrame has 10 rows
- [ ] Accelerometer values are in g (not milli-g)
- [ ] Timestamps are in milliseconds (13-digit numbers)
- [ ] No duplicate rows when using sample data
- [ ] `is_duplicate` column is boolean dtype
- [ ] `interpolated` column is boolean dtype

### 5.3 Metrics

- [ ] `duration_s` ≈ 9.0 for sample 10-packet file
- [ ] `actual_frequency_hz` ≈ 25.0
- [ ] `sample_count` == 250
- [ ] `acc_norm_mean` is in range [0.5, 2.0]
- [ ] `gps_distance_m` > 0
- [ ] `data_quality_score` between 0 and 100
- [ ] `packet_loss_estimate` == 0.0 for clean sample data

### 5.4 Plotter

- [ ] `accelerometer_xyz.png` created and non-empty (> 10KB)
- [ ] `gyroscope_xyz.png` created and non-empty
- [ ] `heart_rate.png` created and non-empty
- [ ] `gps_track.png` created and non-empty
- [ ] `altitude_profile.png` created and non-empty
- [ ] `sensor_overview.png` created and non-empty (dashboard)
- [ ] No matplotlib display window opened (Agg backend)

### 5.5 Reporter

- [ ] `summary.txt` created with correct header and session info
- [ ] `imu_data.csv` has correct column headers and data rows
- [ ] `gps_data.csv` has correct column headers and data rows
- [ ] `metrics.json` is valid JSON (parseable with `json.load()`)
- [ ] NaN values in metrics.json are serialized as `null` (not "NaN")

---

## Section 6 — Regression Tests

Run after every code change to the Python pipeline:

```bash
cd D:/CLAUDE_PROJECTS/GARMIN
python -m pytest 05_tests/test_python/ -v --tb=short
```

- [ ] All tests in `test_parser.py` pass (30 tests)
- [ ] All tests in `test_normalizer.py` pass (21 tests)
- [ ] All tests in `test_metrics.py` pass (23 tests)
- [ ] Total: 0 failures, 0 errors

---

## Sign-off

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Developer | | | |
| Tech Lead | | | |
| QA | | | |
