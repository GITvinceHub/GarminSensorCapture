"""
Unit tests for modules/normalizer.py

Tests cover: column presence, unit conversions, timestamp sorting,
duplicate detection, GPS schema.
"""

import os
import sys
import pytest
import numpy as np
import pandas as pd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../03_python_analysis"))

from modules.normalizer import normalize_data, _empty_imu_df, _empty_gps_df


# ── Helpers ───────────────────────────────────────────────────────────

def _make_packet(pi: int = 0, n_samples: int = 5) -> dict:
    """Build a minimal valid packet dict."""
    samples = []
    for i in range(n_samples):
        samples.append({
            "t":  i * 40,
            "ax": 15000.0,   # 15 g in milli-g → should become 15.0 g
            "ay": -983000.0,
            "az": 124000.0,
            "gx": 10.0,      # deg/s (unchanged)
            "gy": -3.0,
            "gz": 1.0,
            "mx": 22.5,
            "my": -15.3,
            "mz": 44.1,
            "hr": 72 + i,
        })

    return {
        "received_at": "2024-04-22T14:30:22.000Z",
        "pv":  1,
        "sid": "20240422_143022",
        "pi":  pi,
        "dtr": 1713794022000 + pi * 1000,
        "s":   samples,
        "gps": {
            "lat": 48.8566 + pi * 0.001,
            "lon": 2.3522  + pi * 0.001,
            "alt": 35.0,
            "spd": 1.2,
            "hdg": 270.0,
            "acc": 5.0,
            "ts":  1713794022 + pi,
        },
        "meta": {"bat": 85, "temp": 22.5},
        "ef": 0,
    }


# ── test_normalize_imu_columns ────────────────────────────────────────

class TestNormalizeImuColumns:
    """Verify that the IMU DataFrame has the expected column schema."""

    def test_all_required_columns_present(self):
        """imu_df should have all expected columns."""
        packets = [_make_packet()]
        imu_df, _ = normalize_data(packets)
        expected = [
            "timestamp_ms", "session_id", "packet_index", "sample_index",
            "ax_g", "ay_g", "az_g",
            "gx_dps", "gy_dps", "gz_dps",
            "mx_uT", "my_uT", "mz_uT",
            "hr_bpm", "received_at", "is_duplicate", "interpolated",
        ]
        for col in expected:
            assert col in imu_df.columns, f"Missing column: {col}"

    def test_imu_row_count(self):
        """Row count should equal total samples across all packets."""
        packets = [_make_packet(pi=i, n_samples=5) for i in range(3)]
        imu_df, _ = normalize_data(packets)
        assert len(imu_df) == 15  # 3 packets × 5 samples

    def test_empty_packets_returns_empty_df(self):
        """Empty input should return DataFrames with correct schema but no rows."""
        imu_df, gps_df = normalize_data([])
        assert len(imu_df) == 0
        assert "timestamp_ms" in imu_df.columns

    def test_is_duplicate_column_is_bool(self):
        """is_duplicate column should be boolean dtype."""
        packets = [_make_packet()]
        imu_df, _ = normalize_data(packets)
        assert imu_df["is_duplicate"].dtype == bool

    def test_interpolated_column_is_bool(self):
        """interpolated column should be boolean dtype."""
        packets = [_make_packet()]
        imu_df, _ = normalize_data(packets)
        assert imu_df["interpolated"].dtype == bool


# ── test_normalize_gps_columns ────────────────────────────────────────

class TestNormalizeGpsColumns:
    """Verify that the GPS DataFrame has the expected column schema."""

    def test_all_required_gps_columns_present(self):
        """gps_df should have all expected GPS columns."""
        packets = [_make_packet()]
        _, gps_df = normalize_data(packets)
        expected = [
            "timestamp_ms", "session_id", "packet_index",
            "lat_deg", "lon_deg", "alt_m", "speed_ms",
            "heading_deg", "accuracy_m", "received_at", "is_duplicate",
        ]
        for col in expected:
            assert col in gps_df.columns, f"Missing GPS column: {col}"

    def test_gps_row_per_packet_with_fix(self):
        """One GPS row should be produced for each packet with valid GPS."""
        packets = [_make_packet(pi=i) for i in range(4)]
        _, gps_df = normalize_data(packets)
        assert len(gps_df) == 4

    def test_no_gps_produces_empty_df(self):
        """Packets without GPS should produce empty GPS DataFrame."""
        pkt = _make_packet()
        pkt["gps"] = None
        _, gps_df = normalize_data([pkt])
        assert len(gps_df) == 0

    def test_gps_lat_lon_values(self):
        """GPS lat/lon should match input values."""
        pkt = _make_packet()
        _, gps_df = normalize_data([pkt])
        assert abs(gps_df["lat_deg"].iloc[0] - 48.8566) < 1e-6
        assert abs(gps_df["lon_deg"].iloc[0] - 2.3522) < 1e-6


# ── test_unit_conversion ──────────────────────────────────────────────

class TestUnitConversion:
    """Verify that unit conversions are applied correctly."""

    def test_accelerometer_milli_g_to_g(self):
        """Accelerometer values (milli-g) should be converted to g."""
        pkt = _make_packet(n_samples=1)
        pkt["s"][0]["ax"] = 1000.0   # 1000 milli-g = 1.0 g
        pkt["s"][0]["ay"] = -9830.0  # -9.830 g
        pkt["s"][0]["az"] = 0.0

        imu_df, _ = normalize_data([pkt])
        assert abs(imu_df["ax_g"].iloc[0] - 1.0) < 1e-9
        assert abs(imu_df["ay_g"].iloc[0] - (-9.830)) < 1e-6
        assert imu_df["az_g"].iloc[0] == 0.0

    def test_gyroscope_unchanged(self):
        """Gyroscope values should remain in deg/s (no conversion)."""
        pkt = _make_packet(n_samples=1)
        pkt["s"][0]["gx"] = 45.0   # deg/s
        pkt["s"][0]["gy"] = -30.0
        pkt["s"][0]["gz"] = 10.0

        imu_df, _ = normalize_data([pkt])
        assert abs(imu_df["gx_dps"].iloc[0] - 45.0) < 1e-9
        assert abs(imu_df["gy_dps"].iloc[0] - (-30.0)) < 1e-9
        assert abs(imu_df["gz_dps"].iloc[0] - 10.0) < 1e-9

    def test_hr_zero_becomes_nan(self):
        """Heart rate value of 0 should be converted to NaN."""
        pkt = _make_packet(n_samples=1)
        pkt["s"][0]["hr"] = 0
        imu_df, _ = normalize_data([pkt])
        assert np.isnan(imu_df["hr_bpm"].iloc[0])

    def test_hr_nonzero_preserved(self):
        """Non-zero heart rate should be preserved as float."""
        pkt = _make_packet(n_samples=1)
        pkt["s"][0]["hr"] = 75
        imu_df, _ = normalize_data([pkt])
        assert imu_df["hr_bpm"].iloc[0] == 75.0

    def test_gps_timestamp_seconds_to_ms(self):
        """GPS timestamp (Unix seconds) should be converted to milliseconds."""
        pkt = _make_packet()
        ts_s = 1713794022
        pkt["gps"]["ts"] = ts_s
        _, gps_df = normalize_data([pkt])
        assert gps_df["timestamp_ms"].iloc[0] == ts_s * 1000

    def test_absolute_timestamp_computation(self):
        """IMU absolute timestamps should be dtr + t_offset."""
        pkt = _make_packet(n_samples=3)
        dtr = 1713794022000
        pkt["dtr"] = dtr
        pkt["s"][0]["t"] = 0
        pkt["s"][1]["t"] = 40
        pkt["s"][2]["t"] = 80

        imu_df, _ = normalize_data([pkt])
        assert imu_df["timestamp_ms"].iloc[0] == dtr
        assert imu_df["timestamp_ms"].iloc[1] == dtr + 40
        assert imu_df["timestamp_ms"].iloc[2] == dtr + 80


# ── test_timestamp_sorting ────────────────────────────────────────────

class TestTimestampSorting:
    """Verify that IMU and GPS DataFrames are sorted by timestamp."""

    def test_imu_sorted_ascending(self):
        """IMU DataFrame should be sorted by timestamp_ms ascending."""
        # Create packets with reversed order
        packets = [_make_packet(pi=i) for i in range(3, -1, -1)]  # pi=3,2,1,0
        imu_df, _ = normalize_data(packets)
        ts = imu_df["timestamp_ms"].values
        assert all(ts[i] <= ts[i+1] for i in range(len(ts)-1))

    def test_gps_sorted_ascending(self):
        """GPS DataFrame should be sorted by timestamp_ms ascending."""
        packets = [_make_packet(pi=i) for i in range(4, -1, -1)]  # pi=4..0
        _, gps_df = normalize_data(packets)
        ts = gps_df["timestamp_ms"].values
        assert all(ts[i] <= ts[i+1] for i in range(len(ts)-1))


# ── test_duplicate_detection ──────────────────────────────────────────

class TestDuplicateDetection:
    """Verify that duplicate timestamps are detected and marked."""

    def test_duplicate_timestamps_marked(self):
        """Samples with identical timestamps should have is_duplicate=True."""
        pkt1 = _make_packet(pi=0, n_samples=1)
        pkt2 = _make_packet(pi=1, n_samples=1)

        # Force same dtr so samples have identical timestamp_ms
        pkt1["dtr"] = 1713794022000
        pkt2["dtr"] = 1713794022000  # same as pkt1
        pkt1["s"][0]["t"] = 0
        pkt2["s"][0]["t"] = 0

        imu_df, _ = normalize_data([pkt1, pkt2])

        # One should be original, one duplicate
        assert imu_df["is_duplicate"].sum() == 1

    def test_unique_timestamps_not_marked(self):
        """Samples with unique timestamps should not be marked as duplicates."""
        packets = [_make_packet(pi=i, n_samples=5) for i in range(3)]
        imu_df, _ = normalize_data(packets)
        # All timestamps should be unique (different dtr + different t offsets)
        assert imu_df["is_duplicate"].sum() == 0

    def test_gps_duplicates_marked(self):
        """GPS rows with same timestamp should have is_duplicate=True."""
        pkt1 = _make_packet(pi=0)
        pkt2 = _make_packet(pi=1)
        # Force same GPS ts
        pkt1["gps"]["ts"] = 1713794022
        pkt2["gps"]["ts"] = 1713794022

        _, gps_df = normalize_data([pkt1, pkt2])
        assert gps_df["is_duplicate"].sum() == 1
