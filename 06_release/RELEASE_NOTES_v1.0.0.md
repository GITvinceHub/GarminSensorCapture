# Release Notes — GarminSensorCapture v1.0.0

**Release Date:** 2024-04-22  
**Status:** Initial Release

---

## Overview

GarminSensorCapture v1.0.0 is the first production release of the full sensor capture and analysis system for the Garmin fēnix 8 Pro. It provides:

- A **Monkey C watch app** (Connect IQ 6.x) for real-time IMU + GPS capture at 25 Hz
- An **Android Kotlin companion app** that receives data via BLE and saves it as JSONL
- A **Python 3.10+ analysis pipeline** that produces metrics, plots, and CSV/JSON reports

---

## What's New in v1.0.0

### Watch App (Connect IQ)

- Real-time capture: accelerometer (ax, ay, az), gyroscope (gx, gy, gz), magnetometer (mx, my, mz), heart rate, GPS
- Target frequency: 25 Hz IMU, 1 Hz GPS
- Protocol v1 JSON serialization with compact keys (pv, sid, pi, dtr, s, gps, meta, ef)
- Batching: 25 samples/packet (≈ 1 packet/second)
- BLE transmission via Connect IQ AppChannel with automatic reconnect (30s timer)
- Error flags bitmask (ef): sensor failure, GPS timeout, BLE overflow, memory pressure, user event marker
- Session ID format: `YYYYMMDD_HHMMSS`
- Status display: recording state, sample count, frequency, packet count, GPS fix, BLE status, battery
- Memory-safe: buffer capped at 100 packets; urgent flush at 80 elements (≈ 180KB heap)
- Packet serializer 4096-byte guard with graceful truncation

### Android Companion App

- Kotlin + Android API 26+ (Android 8.0+)
- Connect IQ Mobile SDK integration for AppChannel reception
- Real-time UI: packets received, throughput (packets/sec), file size, packet loss %, GPS fix, battery
- JSONL storage with enrichment: adds `received_at` ISO timestamp to each packet
- File rotation at 100MB with sequential naming
- ZIP export and FileProvider-based sharing
- Gap detection and packet loss percentage calculation
- StateFlow/ViewModel architecture (Jetpack Lifecycle)

### Python Analysis Pipeline

- **parser.py** — JSONL reading, validation (required fields, non-empty sid, non-negative pi, list-type samples), graceful error handling
- **normalizer.py** — Unit conversion (milli-g → g, Unix seconds → ms), timestamp sorting, duplicate detection, linear interpolation for gaps < 200ms
- **metrics.py** — Duration, frequency, sample count, packet loss, accelerometer/gyroscope norm statistics, heart rate statistics, GPS distance (Haversine), altitude gain/loss, data quality score 0–100
- **plotter.py** — 6 plots: accelerometer_xyz.png, gyroscope_xyz.png, heart_rate.png, gps_track.png (colored by speed), altitude_profile.png, sensor_overview.png (6-panel dashboard)
- **reporter.py** — summary.txt (human-readable), imu_data.csv, gps_data.csv, metrics.json (NaN → null)

### Test Suite

- 74 automated pytest unit tests covering parser, normalizer, and metrics modules
- Test plan, test cases, integration checklist, and test report documents

---

## Supported Devices

### Watch

| Device | Part Name | Status |
|--------|-----------|--------|
| Garmin fēnix 8 Pro | fenix8pro | Primary target |
| Garmin fēnix 8 (standard) | fenix8 | Supported |
| Garmin fēnix 7 Pro | fenix7pro | Supported |
| Garmin fēnix 7 | fenix7 | Supported |

### Android

| Android Version | API Level | Status |
|----------------|-----------|--------|
| Android 8.0+ | API 26+ | Required minimum |
| Android 10+ | API 29+ | Recommended |
| Android 14 | API 34 | Tested on API ≤ 33 (see RR-003) |

---

## System Requirements

### Build Requirements

| Tool | Version | Notes |
|------|---------|-------|
| Connect IQ SDK | 6.x | Required for watch app compilation |
| Android Studio | Hedgehog 2023.1.1+ | Required for Android app |
| Kotlin | 1.9.0 | Bundled with Android Studio |
| Gradle | 8.1.0 | Via Gradle wrapper |
| Python | 3.10+ | For analysis pipeline |

### Runtime Requirements

| Component | Requirement |
|-----------|-------------|
| Garmin device | fēnix 8 Pro or compatible (see above) |
| Android device | API 26+, Bluetooth 4.2+ |
| Garmin Connect Mobile | Installed and logged in |
| Python packages | numpy≥1.24, pandas≥2.0, matplotlib≥3.7, scipy≥1.11 |

---

## Known Limitations

| ID | Description | Workaround |
|----|-------------|------------|
| RR-001 | Magnetometer may be unavailable in simulator | Test on physical device |
| RR-002 | Buffer stress under long BLE disconnect | Keep Android app in foreground |
| RR-003 | FileProvider export untested on Android 14 | Use API 29–33 for export |
| RR-005 | GPS cold start up to 15 minutes | Start recording outdoors, wait for fix |
| — | No background capture on watch | Keep watch app in foreground |
| — | Connect IQ heap limits: ~260KB max | Session buffer capped at 100 packets |

---

## File Structure

```
GARMIN/
├── 01_watch_app_connectiq/      Connect IQ Monkey C project
│   ├── manifest.xml
│   ├── source/                  7 .mc source files
│   └── resources/               strings, layouts, properties
│
├── 02_android_companion/        Android Kotlin project
│   ├── app/build.gradle
│   ├── AndroidManifest.xml
│   └── app/src/main/java/       8 Kotlin source files
│
├── 03_python_analysis/          Python pipeline
│   ├── main.py
│   ├── requirements.txt
│   ├── modules/                 5 modules (parser, normalizer, metrics, plotter, reporter)
│   └── sample_data/             sample_session.jsonl (10 packets)
│
├── 04_docs/                     Documentation
│   ├── 01_architecture.md
│   ├── 02_protocol_communication.md
│   ├── 03_data_schema.md
│   ├── 04_hypotheses.md
│   ├── 05_exploitation_guide.md
│   └── 06_troubleshooting.md
│
├── 05_tests/                    Test suite
│   ├── test_python/             74 pytest unit tests (3 files + conftest)
│   ├── test_plan.md
│   ├── test_cases.md
│   ├── checklist_integration.md
│   └── test_report.md
│
├── 06_release/                  This directory
│   ├── RELEASE_NOTES_v1.0.0.md
│   ├── CHECKLIST_MISE_EN_ROUTE.md
│   └── create_archive.sh
│
├── README.md                    Project overview
└── .gitignore
```

---

## Changelog

### v1.0.0 (2024-04-22)
- Initial release: all components implemented
- 74 automated unit tests for Python pipeline
- Full documentation (6 documents in 04_docs/)
- Sample data for development/testing

---

## License

This project is proprietary. All rights reserved.

---

## Contact

See `04_docs/05_exploitation_guide.md` for build and deployment instructions.
