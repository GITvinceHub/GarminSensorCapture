# Test Plan — GarminSensorCapture v1.0.0

**Document ID:** TP-001  
**Version:** 1.0.0  
**Date:** 2024-04-22  
**Status:** Approved

---

## 1. Scope

This test plan covers all testable components of the GarminSensorCapture system:

| Layer | Component | Test Type |
|-------|-----------|-----------|
| Watch App (Monkey C) | SensorManager, BatchManager, PacketSerializer, CommunicationManager | Manual + Simulator |
| Android App (Kotlin) | GarminReceiver, FileLogger, SessionManager, ExportManager | Manual + Device |
| Python Pipeline | parser, normalizer, metrics, plotter, reporter | Automated (pytest) |
| Integration | Watch→Android BLE link | Manual (device pair) |
| End-to-end | Full session capture + analysis | Manual |

---

## 2. Test Levels

### 2.1 Unit Tests (Automated)

- **Framework:** pytest 7.x
- **Target:** `03_python_analysis/modules/` (parser, normalizer, metrics)
- **Location:** `05_tests/test_python/`
- **Coverage goal:** ≥ 80% statement coverage on all Python modules
- **Run command:**
  ```bash
  cd D:/CLAUDE_PROJECTS/GARMIN
  python -m pytest 05_tests/test_python/ -v --tb=short
  ```

### 2.2 Integration Tests (Semi-automated)

- **Target:** Android GarminReceiver + FileLogger (Instrumented tests on device)
- **Framework:** Android JUnit4 + Espresso
- **Location:** `02_android_companion/app/src/androidTest/`
- **Trigger:** Manual, requires physical Android device (API 26+)

### 2.3 System Tests (Manual)

- **Target:** Complete watch→BLE→Android→JSONL pipeline
- **Requires:** Garmin fēnix 8 Pro + Android device (API 26+) + Garmin Connect Mobile
- **Test scenarios:** See `05_tests/test_cases.md`

### 2.4 End-to-End Tests (Manual)

- **Target:** Full pipeline including Python analysis
- **Requires:** All of the above + Python 3.10+ environment
- **Output validation:** summary.txt, metrics.json, all PNG plots exist and are non-empty

---

## 3. Test Environment

### 3.1 Python Unit Test Environment

| Requirement | Value |
|-------------|-------|
| Python | 3.10 or 3.11 |
| pytest | ≥ 7.0 |
| numpy | ≥ 1.24 |
| pandas | ≥ 2.0 |
| scipy | ≥ 1.11 |
| matplotlib | ≥ 3.7 |
| OS | Windows 10/11, Ubuntu 22.04, macOS 12+ |

### 3.2 Watch App Build Environment

| Requirement | Value |
|-------------|-------|
| Connect IQ SDK | 6.x (minimum 3.3.0 API) |
| Target device | fēnix 8 Pro (part: fenix8pro) |
| Simulator | Connect IQ Simulator v6.x |

### 3.3 Android Build Environment

| Requirement | Value |
|-------------|-------|
| Android Studio | Hedgehog (2023.1.1) or later |
| Gradle | 8.1.0 |
| Kotlin | 1.9.0 |
| Min API | 26 (Android 8.0) |
| Test device | Android 10+ (API 29+) recommended |

---

## 4. Test Data

### 4.1 Synthetic Data (Automated Tests)

Python unit tests use synthetic DataFrames built by helper functions:
- `_make_imu_df(n, freq_hz, base_ts)` — configurable synthetic IMU data
- `_make_gps_df(n, base_ts)` — configurable synthetic GPS data
- `_make_packet(pi, n_samples)` — valid raw packet dict
- `_make_valid_packet(pi)` — minimal packet for parser tests

### 4.2 Sample JSONL File

`03_python_analysis/sample_data/sample_session.jsonl` — 10 packets × 25 samples with:
- Sinusoidal IMU values simulating realistic motion
- Sequential GPS fixes at 48.8566°N, 2.3522°E (Paris)
- Valid session ID: `20240422_143022`

### 4.3 Real Capture Data

For system tests, use data captured from actual watch session (minimum 60s recording).

---

## 5. Entry and Exit Criteria

### 5.1 Entry Criteria

- Python 3.10+ installed with all requirements from `requirements.txt`
- Source code complete in `03_python_analysis/modules/`
- All test files present in `05_tests/test_python/`

### 5.2 Exit Criteria (Unit Tests)

- All pytest tests pass (0 failures, 0 errors)
- No regressions from previous run
- Coverage ≥ 80% on parser.py, normalizer.py, metrics.py

### 5.3 Exit Criteria (System Tests)

- Watch app successfully transmits at least 10 packets in a 60s session
- Android saves valid JSONL file (non-empty, parseable)
- Python pipeline produces all expected output files without error
- `data_quality_score` ≥ 60 for a normal session

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Magnetometer not available on all fēnix variants | Medium | Low | Hypothesis H-005; graceful null handling |
| BLE MTU limitation causing packet truncation | Medium | High | PacketSerializer 4096-char guard |
| Connect IQ heap exhaustion | Low | High | 100-packet buffer cap, urgent flush at 80 |
| GPS cold start delay (5–15 min) | High | Low | Null GPS fields allowed by protocol |
| Android BLE disconnect mid-session | Medium | Medium | Queue + reconnect with 30s timer |
| Python NaN serialization to JSON | Low | Medium | `_json_default()` handler in reporter |

---

## 7. Test Schedule

| Phase | Activity | Owner |
|-------|----------|-------|
| T+0 | Run Python unit tests | Developer |
| T+1d | Connect IQ simulator smoke test | Developer |
| T+2d | Android instrumented tests | Developer |
| T+3d | Full device integration test (≥ 5 sessions) | Developer |
| T+5d | End-to-end validation with Python analysis | Developer |
| T+7d | Final sign-off, generate test_report.md | Tech Lead |

---

## 8. Test Metrics

| Metric | Target |
|--------|--------|
| Python unit test pass rate | 100% |
| Python code coverage (parser + normalizer + metrics) | ≥ 80% |
| BLE packet loss in controlled environment | < 5% |
| Watch app memory usage under load | < 220KB heap |
| Session capture reliability (10 min session) | ≥ 95% packets received |
| Python pipeline execution time (10k samples) | < 30s |
