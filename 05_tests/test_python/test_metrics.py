"""
Unit tests for modules/metrics.py

Tests cover: duration calculation, frequency measurement,
accelerometer norm computation, empty DataFrame handling,
GPS metrics, packet loss estimation.
"""

import os
import sys
import pytest
import numpy as np
import pandas as pd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../03_python_analysis"))

from modules.metrics import (
    compute_metrics,
    _compute_time_metrics,
    _compute_sample_metrics,
    _compute_packet_loss,
    _compute_imu_metrics,
    _compute_hr_metrics,
    _compute_gps_metrics,
    _compute_quality_score,
    _haversine,
    NOMINAL_FREQUENCY_HZ,
)


# ── Helpers ───────────────────────────────────────────────────────────

def _make_imu_df(n: int = 100, freq_hz: float = 25.0,
                 base_ts: int = 1713794022000) -> pd.DataFrame:
    """Create a synthetic IMU DataFrame at given frequency."""
    period_ms = int(1000.0 / freq_hz)
    data = {
        "timestamp_ms":  [base_ts + i * period_ms for i in range(n)],
        "session_id":    ["test_session"] * n,
        "packet_index":  [i // 25 for i in range(n)],
        "sample_index":  [i % 25 for i in range(n)],
        "ax_g":          np.zeros(n).tolist(),
        "ay_g":          np.zeros(n).tolist(),
        "az_g":          (np.ones(n) * -1.0).tolist(),  # ~1g downward
        "gx_dps":        np.zeros(n).tolist(),
        "gy_dps":        np.zeros(n).tolist(),
        "gz_dps":        np.zeros(n).tolist(),
        "mx_uT":         np.zeros(n).tolist(),
        "my_uT":         np.zeros(n).tolist(),
        "mz_uT":         np.zeros(n).tolist(),
        "hr_bpm":        [75.0] * n,
        "received_at":   ["2024-04-22T14:30:22.000Z"] * n,
        "is_duplicate":  [False] * n,
        "interpolated":  [False] * n,
    }
    df = pd.DataFrame(data)
    df["timestamp_ms"] = df["timestamp_ms"].astype("int64")
    return df


def _make_gps_df(n: int = 10, base_ts: int = 1713794022000) -> pd.DataFrame:
    """Create a synthetic GPS DataFrame."""
    data = {
        "timestamp_ms":  [base_ts + i * 1000 for i in range(n)],
        "session_id":    ["test_session"] * n,
        "packet_index":  list(range(n)),
        "lat_deg":       [48.8566 + i * 0.0001 for i in range(n)],
        "lon_deg":       [2.3522  + i * 0.0001 for i in range(n)],
        "alt_m":         [35.0 + i * 1.0 for i in range(n)],
        "speed_ms":      [1.5 + i * 0.1 for i in range(n)],
        "heading_deg":   [270.0] * n,
        "accuracy_m":    [5.0] * n,
        "received_at":   ["2024-04-22T14:30:22.000Z"] * n,
        "is_duplicate":  [False] * n,
    }
    df = pd.DataFrame(data)
    df["timestamp_ms"] = df["timestamp_ms"].astype("int64")
    return df


# ── test_duration_calculation ─────────────────────────────────────────

class TestDurationCalculation:
    """Tests for session duration computation."""

    def test_duration_correct_for_25hz_100_samples(self):
        """Duration for 100 samples at 25 Hz should be ~3.96 seconds."""
        imu_df = _make_imu_df(n=100, freq_hz=25.0)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        # 100 samples at 40ms intervals = 99 intervals = 3960ms = 3.96s
        assert abs(metrics["duration_s"] - 3.96) < 0.1

    def test_duration_zero_for_single_sample(self):
        """Duration should be 0 for a single sample."""
        imu_df = _make_imu_df(n=1, freq_hz=25.0)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["duration_s"] == 0.0

    def test_duration_zero_for_empty_df(self):
        """Duration should be 0 for empty DataFrames."""
        imu_df = pd.DataFrame(columns=["timestamp_ms", "session_id", "ax_g"])
        gps_df = pd.DataFrame(columns=["timestamp_ms", "lat_deg"])
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["duration_s"] == 0.0

    def test_start_and_end_timestamps_set(self):
        """start_time_ms and end_time_ms should be set correctly."""
        base = 1713794022000
        imu_df = _make_imu_df(n=50, freq_hz=25.0, base_ts=base)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["start_time_ms"] == base
        # 50 samples × 40ms = 49 × 40 = 1960ms offset
        assert metrics["end_time_ms"] == base + 49 * 40


# ── test_frequency_measurement ────────────────────────────────────────

class TestFrequencyMeasurement:
    """Tests for actual frequency estimation."""

    def test_frequency_25hz_exact(self):
        """Frequency should be measured as 25.0 Hz for exact 25 Hz data."""
        imu_df = _make_imu_df(n=250, freq_hz=25.0)  # 10s at 25Hz
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert abs(metrics["actual_frequency_hz"] - 25.0) < 0.5

    def test_frequency_10hz(self):
        """Frequency should be measured as ~10 Hz for 10 Hz data."""
        imu_df = _make_imu_df(n=100, freq_hz=10.0)  # 10s at 10Hz
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert abs(metrics["actual_frequency_hz"] - 10.0) < 0.5

    def test_sample_count_matches_df_length(self):
        """sample_count should match the number of non-duplicate rows."""
        imu_df = _make_imu_df(n=75)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["sample_count"] == 75

    def test_nominal_frequency_constant(self):
        """nominal_frequency_hz should always be 25.0."""
        imu_df = _make_imu_df(n=10)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["nominal_frequency_hz"] == NOMINAL_FREQUENCY_HZ


# ── test_acc_norm_computation ─────────────────────────────────────────

class TestAccNormComputation:
    """Tests for accelerometer norm calculation."""

    def test_static_1g_downward(self):
        """A device lying flat should have acc norm ≈ 1.0 g."""
        imu_df = _make_imu_df(n=100)
        # Set az = -1.0g, ax = ay = 0 (already set in helper)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert abs(metrics["acc_norm_mean"] - 1.0) < 0.01
        assert metrics["acc_norm_std"] < 0.01
        assert abs(metrics["acc_norm_max"] - 1.0) < 0.01

    def test_acc_norm_non_negative(self):
        """Accelerometer norm should always be non-negative."""
        imu_df = _make_imu_df(n=50)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["acc_norm_mean"] >= 0
        assert metrics["acc_norm_max"] >= 0

    def test_gyro_norm_zero_for_static_device(self):
        """Gyroscope norm should be 0 when all gyro values are 0."""
        imu_df = _make_imu_df(n=50)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["gyro_norm_mean"] == 0.0
        assert metrics["gyro_norm_max"] == 0.0

    def test_acc_metrics_with_motion(self):
        """Accelerometer metrics should reflect actual acceleration."""
        imu_df = _make_imu_df(n=100)
        imu_df["ax_g"] = np.random.normal(0.5, 0.1, 100)
        imu_df["ay_g"] = np.random.normal(-0.2, 0.05, 100)
        imu_df["az_g"] = np.random.normal(-1.0, 0.05, 100)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        # With motion, norm should be > 1g due to lateral acceleration
        assert metrics["acc_norm_mean"] > 0.5


# ── test_empty_dataframe_handled ──────────────────────────────────────

class TestEmptyDataframeHandled:
    """Tests that empty DataFrames don't cause errors."""

    def test_both_empty_returns_defaults(self):
        """compute_metrics with empty DFs should return a dict with zero/None values."""
        imu_df = pd.DataFrame(columns=[
            "timestamp_ms", "session_id", "packet_index", "sample_index",
            "ax_g", "ay_g", "az_g", "gx_dps", "gy_dps", "gz_dps",
            "mx_uT", "my_uT", "mz_uT", "hr_bpm", "received_at",
            "is_duplicate", "interpolated"
        ])
        gps_df = pd.DataFrame(columns=[
            "timestamp_ms", "session_id", "packet_index",
            "lat_deg", "lon_deg", "alt_m", "speed_ms",
            "heading_deg", "accuracy_m", "received_at", "is_duplicate"
        ])
        metrics = compute_metrics(imu_df, gps_df)

        assert metrics["duration_s"] == 0.0
        assert metrics["sample_count"] == 0
        assert metrics["gps_sample_count"] == 0
        assert metrics["packet_loss_estimate"] == 0.0

    def test_empty_imu_no_exception(self):
        """Empty IMU DataFrame should not raise any exception."""
        imu_df = pd.DataFrame(columns=["timestamp_ms", "is_duplicate"])
        gps_df = _make_gps_df(n=3)
        metrics = compute_metrics(imu_df, gps_df)
        assert "duration_s" in metrics

    def test_empty_gps_no_exception(self):
        """Empty GPS DataFrame should not raise any exception."""
        imu_df = _make_imu_df(n=50)
        gps_df = pd.DataFrame(columns=["timestamp_ms", "lat_deg", "lon_deg", "is_duplicate"])
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["gps_sample_count"] == 0
        assert metrics["gps_distance_m"] == 0.0


# ── test_packet_loss_estimate ─────────────────────────────────────────

class TestPacketLossEstimate:
    """Tests for packet loss percentage estimation."""

    def test_no_gaps_zero_loss(self):
        """Continuous data should give 0% loss."""
        imu_df = _make_imu_df(n=100, freq_hz=25.0)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["packet_loss_estimate"] == 0.0

    def test_large_gap_detected(self):
        """A gap > 2× nominal period should result in non-zero loss."""
        base = 1713794022000
        # Create data with a 500ms gap in the middle (at 25Hz, that's ~12 missing samples)
        ts_before = [base + i * 40 for i in range(25)]   # 0..24
        ts_after  = [base + 25 * 40 + 500 + i * 40 for i in range(25)]  # gap!
        timestamps = ts_before + ts_after

        rows = []
        for i, ts in enumerate(timestamps):
            rows.append({
                "timestamp_ms": ts,
                "session_id": "test",
                "packet_index": i // 25,
                "sample_index": i % 25,
                "ax_g": 0.0, "ay_g": 0.0, "az_g": -1.0,
                "gx_dps": 0.0, "gy_dps": 0.0, "gz_dps": 0.0,
                "mx_uT": 0.0, "my_uT": 0.0, "mz_uT": 0.0,
                "hr_bpm": 75.0, "received_at": "2024-04-22T14:30:22.000Z",
                "is_duplicate": False, "interpolated": False,
            })
        imu_df = pd.DataFrame(rows)
        imu_df["timestamp_ms"] = imu_df["timestamp_ms"].astype("int64")
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["packet_loss_estimate"] > 0.0


# ── test_haversine ────────────────────────────────────────────────────

class TestHaversine:
    """Tests for the Haversine distance helper."""

    def test_same_point_zero_distance(self):
        """Distance from a point to itself should be 0."""
        d = _haversine(48.8566, 2.3522, 48.8566, 2.3522)
        assert d == 0.0

    def test_known_distance(self):
        """Distance between Paris and London ≈ 343 km."""
        # Paris: 48.8566°N, 2.3522°E
        # London: 51.5074°N, -0.1278°W
        d = _haversine(48.8566, 2.3522, 51.5074, -0.1278)
        assert 340_000 < d < 350_000  # ~343 km

    def test_short_distance(self):
        """A 100m offset should give approximately 100m distance."""
        # 0.0009° lat ≈ 100m
        d = _haversine(48.8566, 2.3522, 48.8575, 2.3522)
        assert 50 < d < 150


# ── test_quality_score ────────────────────────────────────────────────

class TestQualityScore:
    """Tests for the data quality score."""

    def test_perfect_data_high_score(self):
        """Perfect data should produce a score close to 100."""
        imu_df = _make_imu_df(n=250, freq_hz=25.0)  # 10s of perfect 25Hz
        gps_df = _make_gps_df(n=10)
        metrics = compute_metrics(imu_df, gps_df)
        assert metrics["data_quality_score"] >= 70  # Generous lower bound

    def test_short_session_lower_score(self):
        """A very short session should have a lower quality score."""
        imu_df_short = _make_imu_df(n=5, freq_hz=25.0)   # < 10s
        imu_df_long  = _make_imu_df(n=250, freq_hz=25.0)  # > 10s
        gps_df = _make_gps_df(n=0)

        m_short = compute_metrics(imu_df_short, gps_df)
        m_long  = compute_metrics(imu_df_long,  gps_df)

        assert m_short["data_quality_score"] < m_long["data_quality_score"]

    def test_score_between_0_and_100(self):
        """Quality score must be in the range [0, 100]."""
        imu_df = _make_imu_df(n=10)
        gps_df = _make_gps_df(n=0)
        metrics = compute_metrics(imu_df, gps_df)
        assert 0.0 <= metrics["data_quality_score"] <= 100.0
