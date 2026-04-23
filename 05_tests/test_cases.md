# Test Cases — GarminSensorCapture v1.0.0

**Document ID:** TC-001  
**Version:** 1.0.0  
**Date:** 2024-04-22

---

## TC-PY-001 — Python Parser: Valid JSONL Parsing

**Module:** `modules/parser.py`  
**Priority:** P1 (Critical)  
**Type:** Unit (automated)

**Prerequisites:**
- Python 3.10+ installed
- `03_python_analysis/modules/parser.py` present

**Test Steps:**
1. Create a JSONL file with 5 valid packets (all required fields: pv, sid, pi, dtr, s)
2. Call `parse_jsonl(path)`
3. Assert return value is a list of length 5
4. Assert each packet contains all keys in `REQUIRED_FIELDS`
5. Assert `packet["sid"]` matches input value

**Expected Result:** 5 dicts returned, all fields preserved, no exception raised.  
**Automated:** Yes — `TestParseValidPacket::test_single_valid_packet`, `test_packet_contains_required_fields`, `test_packet_values_preserved`

---

## TC-PY-002 — Python Parser: Missing Required Field Rejection

**Module:** `modules/parser.py`  
**Priority:** P1 (Critical)  
**Type:** Unit (automated)

**Prerequisites:** Same as TC-PY-001

**Test Steps:**
1. For each of `["pv", "sid", "pi", "dtr", "s"]`:
   a. Create a packet missing that field
   b. Write to JSONL
   c. Call `parse_jsonl(path)`
   d. Assert result is empty list

**Expected Result:** Packets missing any required field are silently skipped; 0 packets returned.  
**Automated:** Yes — `TestParseMissingRequiredField` (parametrized)

---

## TC-PY-003 — Python Parser: Invalid JSON Handling

**Module:** `modules/parser.py`  
**Priority:** P1 (Critical)  
**Type:** Unit (automated)

**Test Steps:**
1. Create JSONL with one malformed line ("not json\n") followed by one valid packet
2. Call `parse_jsonl(path)`
3. Assert result has exactly 1 packet (the valid one)
4. Assert no exception raised

**Expected Result:** Malformed lines are skipped with warning logged; valid packets still returned.  
**Automated:** Yes — `TestParseInvalidJson::test_completely_invalid_json`

---

## TC-PY-004 — Python Parser: Empty File

**Module:** `modules/parser.py`  
**Priority:** P2 (High)  
**Type:** Unit (automated)

**Test Steps:**
1. Create an empty file
2. Call `parse_jsonl(path)`
3. Assert result is `[]`

**Expected Result:** Empty list returned, no exception.  
**Automated:** Yes — `TestParseEmptyFile::test_empty_file`

---

## TC-PY-005 — Python Normalizer: Column Schema Validation

**Module:** `modules/normalizer.py`  
**Priority:** P1 (Critical)  
**Type:** Unit (automated)

**Test Steps:**
1. Call `normalize_data([packet])` with one valid packet (5 samples)
2. Assert `imu_df.columns` contains all 17 expected columns
3. Assert `gps_df.columns` contains all 11 expected GPS columns
4. Assert `len(imu_df) == 5`
5. Assert `len(gps_df) == 1`

**Expected Result:** Both DataFrames have correct schema and row counts.  
**Automated:** Yes — `TestNormalizeImuColumns`, `TestNormalizeGpsColumns`

---

## TC-PY-006 — Python Normalizer: Accelerometer Unit Conversion

**Module:** `modules/normalizer.py`  
**Priority:** P1 (Critical)  
**Type:** Unit (automated)

**Test Steps:**
1. Create packet with `ax = 1000.0` (milli-g)
2. Call `normalize_data([packet])`
3. Assert `imu_df["ax_g"].iloc[0] == 1.0` (converted to g)

**Expected Result:** Accelerometer values divided by 1000 (milli-g → g).  
**Automated:** Yes — `TestUnitConversion::test_accelerometer_milli_g_to_g`

---

## TC-PY-007 — Python Normalizer: Heart Rate Zero → NaN

**Module:** `modules/normalizer.py`  
**Priority:** P2 (High)  
**Type:** Unit (automated)

**Test Steps:**
1. Create packet with `hr = 0` in a sample
2. Call `normalize_data([packet])`
3. Assert `imu_df["hr_bpm"].iloc[0]` is NaN

**Expected Result:** Zero HR values replaced with NaN (sensor not ready).  
**Automated:** Yes — `TestUnitConversion::test_hr_zero_becomes_nan`

---

## TC-PY-008 — Python Normalizer: Duplicate Timestamp Detection

**Module:** `modules/normalizer.py`  
**Priority:** P1 (Critical)  
**Type:** Unit (automated)

**Test Steps:**
1. Create two packets with identical `dtr` and sample `t=0` (produces same timestamp_ms)
2. Call `normalize_data([pkt1, pkt2])`
3. Assert `imu_df["is_duplicate"].sum() == 1`

**Expected Result:** One row marked as duplicate, the other as original.  
**Automated:** Yes — `TestDuplicateDetection::test_duplicate_timestamps_marked`

---

## TC-PY-009 — Python Metrics: Duration Calculation

**Module:** `modules/metrics.py`  
**Priority:** P1 (Critical)  
**Type:** Unit (automated)

**Test Steps:**
1. Create IMU DataFrame: 100 samples at 25 Hz (40ms period)
2. Call `compute_metrics(imu_df, gps_df)`
3. Assert `abs(metrics["duration_s"] - 3.96) < 0.1`

**Expected Result:** Duration = (max_ts - min_ts) / 1000 = 99 × 40ms = 3960ms = 3.96s.  
**Automated:** Yes — `TestDurationCalculation::test_duration_correct_for_25hz_100_samples`

---

## TC-PY-010 — Python Metrics: Packet Loss Detection

**Module:** `modules/metrics.py`  
**Priority:** P1 (Critical)  
**Type:** Unit (automated)

**Test Steps:**
1. Create IMU DataFrame with 500ms gap in the middle (12 missing samples at 25Hz)
2. Call `compute_metrics(imu_df, gps_df)`
3. Assert `metrics["packet_loss_estimate"] > 0.0`

**Expected Result:** Gap larger than 2× nominal period (80ms) is detected and counted.  
**Automated:** Yes — `TestPacketLossEstimate::test_large_gap_detected`

---

## TC-PY-011 — Python Metrics: Haversine Distance

**Module:** `modules/metrics.py`  
**Priority:** P2 (High)  
**Type:** Unit (automated)

**Test Steps:**
1. Call `_haversine(48.8566, 2.3522, 51.5074, -0.1278)` (Paris → London)
2. Assert result is between 340,000m and 350,000m (~343km)

**Expected Result:** Correct spherical distance computed.  
**Automated:** Yes — `TestHaversine::test_known_distance`

---

## TC-PY-012 — Python Metrics: Data Quality Score Range

**Module:** `modules/metrics.py`  
**Priority:** P2 (High)  
**Type:** Unit (automated)

**Test Steps:**
1. Run `compute_metrics` on various DataFrames (normal, short, empty)
2. Assert `0.0 <= metrics["data_quality_score"] <= 100.0` in all cases

**Expected Result:** Quality score always bounded between 0 and 100.  
**Automated:** Yes — `TestQualityScore::test_score_between_0_and_100`

---

## TC-SYS-001 — Watch App: Session Start/Stop

**Module:** Watch App (Monkey C)  
**Priority:** P1 (Critical)  
**Type:** Manual (device or simulator)

**Prerequisites:**
- Connect IQ SDK 6.x installed
- App deployed to simulator or physical fēnix 8 Pro
- Companion app NOT connected (isolated test)

**Test Steps:**
1. Launch app on watch/simulator
2. Press START button (short press)
3. Observe screen: status should show "RECORDING"
4. Wait 5 seconds
5. Press START button again (short press)
6. Observe screen: status should show "IDLE"

**Expected Result:** State transitions correctly IDLE → RECORDING → IDLE. No crash.

---

## TC-SYS-002 — Watch App: Sensor Data Acquisition

**Module:** SensorManager.mc  
**Priority:** P1 (Critical)  
**Type:** Manual (device)

**Prerequisites:**
- Physical Garmin fēnix 8 Pro (not simulator — simulator lacks real sensors)
- App deployed and running

**Test Steps:**
1. Start recording session
2. Move the watch through various orientations
3. Check display: "Samples" counter should increment at ~25/s
4. Check "Freq" display: should show ~25.0 Hz
5. Stop session after 30s

**Expected Result:**
- Sample counter reaches ~750 (30s × 25Hz)
- Displayed frequency between 24.0 and 26.0 Hz
- No memory/heap errors displayed

---

## TC-SYS-003 — Watch App: BLE Packet Transmission

**Module:** CommunicationManager.mc  
**Priority:** P1 (Critical)  
**Type:** Manual (device pair)

**Prerequisites:**
- Physical Garmin fēnix 8 Pro
- Android device with companion app installed
- Both devices paired and Garmin Connect Mobile running

**Test Steps:**
1. Launch companion app on Android
2. Start recording on watch
3. Wait for BLE connection ("BLE: OPEN" on watch display)
4. Record for 60 seconds
5. Stop session
6. Check Android app: packet count should be ~60 (60s / 1s per batch)

**Expected Result:**
- BLE channel opens within 10s
- Packets received: between 55 and 65 (< 10% loss in clean environment)
- JSONL file created with correct structure

---

## TC-SYS-004 — Android: JSONL File Validation

**Module:** FileLogger.kt  
**Priority:** P1 (Critical)  
**Type:** Manual

**Prerequisites:**
- Completed TC-SYS-003 (have a captured JSONL file)
- Python 3.10+ available

**Test Steps:**
1. Export JSONL file from Android (Export button → share to PC)
2. Run: `python main.py exported_session.jsonl`
3. Check that no parsing errors appear
4. Verify output directory contains: summary.txt, metrics.json, imu_data.csv, gps_data.csv
5. Check `data_quality_score` in metrics.json is ≥ 60

**Expected Result:** Python pipeline processes file without errors; all outputs generated.

---

## TC-SYS-005 — Android: File Rotation at 100MB

**Module:** FileLogger.kt  
**Priority:** P3 (Low)  
**Type:** Manual (stress)

**Prerequisites:**
- Android device with companion app
- Long recording session (estimated 6+ hours at 25Hz)

**Test Steps:**
1. Start recording session
2. Continue until file size indicator in UI exceeds 100MB
3. Observe that a new file is created (filename includes rotation index)
4. Verify both files are valid JSONL

**Expected Result:** FileLogger rotates file at 100MB; no data lost; both files parseable.

---

## TC-SYS-006 — End-to-End: 10-minute Session Analysis

**Priority:** P1 (Critical)  
**Type:** End-to-end manual

**Prerequisites:**
- All system components deployed and working
- Python environment ready

**Test Steps:**
1. Start 10-minute recording session (watch → Android)
2. Stop session
3. Export JSONL to PC
4. Run: `python main.py session.jsonl --output-dir ./output/session_test`
5. Verify all output files exist and are non-empty:
   - summary.txt
   - metrics.json
   - imu_data.csv (≥ 15,000 rows expected)
   - gps_data.csv (≥ 600 rows expected at 1Hz)
   - accelerometer_xyz.png, gyroscope_xyz.png, heart_rate.png
   - gps_track.png, altitude_profile.png, sensor_overview.png
6. Open summary.txt and verify:
   - Duration ≈ 600s
   - Sample count ≈ 15,000
   - Frequency ≈ 25.0 Hz
   - Packet loss < 5%

**Expected Result:** Complete analysis succeeds; all metrics within expected ranges.

---

## TC-SYS-007 — Watch App: Event Marking

**Module:** MainDelegate.mc / SessionManager.mc  
**Priority:** P3 (Low)  
**Type:** Manual

**Prerequisites:**
- Physical device, recording session active

**Test Steps:**
1. During active recording, long-press the START button (> 2 seconds)
2. Observe the `ef` field in subsequent packets in the JSONL file

**Expected Result:** The packet following the long-press should have `ef` bitmask with EF_USER_MARK bit set (0x08).

---

## TC-SYS-008 — Python: Empty DataFrame Handling

**Module:** All Python modules  
**Priority:** P2 (High)  
**Type:** Unit (automated)

**Test Steps:**
1. Call `compute_metrics(empty_imu_df, empty_gps_df)` where both are empty DataFrames
2. Assert no exception raised
3. Assert `metrics["duration_s"] == 0.0`
4. Assert `metrics["sample_count"] == 0`

**Expected Result:** Graceful handling of empty input; sensible zero/None defaults returned.  
**Automated:** Yes — `TestEmptyDataframeHandled::test_both_empty_returns_defaults`
