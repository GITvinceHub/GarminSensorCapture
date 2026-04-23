"""
Compute session quality metrics from normalized IMU and GPS DataFrames.

Returns a dictionary of scalar metrics suitable for JSON export and
for annotating plots.
"""

import logging
import math
from typing import Any

import numpy as np
import pandas as pd

logger = logging.getLogger(__name__)

# Nominal IMU frequency assumption (Hz) — accel/gyro rate (mag is lower, typically 25 Hz)
NOMINAL_FREQUENCY_HZ = 100.0
NOMINAL_PERIOD_MS = 1000.0 / NOMINAL_FREQUENCY_HZ  # 10 ms

# Gap threshold for packet loss detection:
# if time between consecutive samples > 2 × nominal period → likely gap
GAP_THRESHOLD_MS = 2.0 * NOMINAL_PERIOD_MS  # 20 ms

# Earth radius for Haversine distance computation (meters)
EARTH_RADIUS_M = 6_371_000.0


def compute_metrics(
    imu_df: pd.DataFrame,
    gps_df: pd.DataFrame
) -> dict[str, Any]:
    """
    Compute session quality and signal metrics.

    Args:
        imu_df: Normalized IMU DataFrame from normalizer.normalize_data()
        gps_df: Normalized GPS DataFrame from normalizer.normalize_data()

    Returns:
        Dictionary with scalar metrics (see 04_docs/03_data_schema.md for keys)
    """
    metrics: dict[str, Any] = {
        "session_id":           _get_session_id(imu_df),
        "nominal_frequency_hz": NOMINAL_FREQUENCY_HZ,
    }

    # ── Time / frequency ──────────────────────────────────────────────
    metrics.update(_compute_time_metrics(imu_df))

    # ── Packet / sample counts ────────────────────────────────────────
    metrics.update(_compute_sample_metrics(imu_df))

    # ── Packet loss estimate ──────────────────────────────────────────
    metrics["packet_loss_estimate"] = _compute_packet_loss(imu_df)

    # ── IMU signal metrics ────────────────────────────────────────────
    metrics.update(_compute_imu_metrics(imu_df))

    # ── Heart rate metrics ────────────────────────────────────────────
    metrics.update(_compute_hr_metrics(imu_df))

    # ── GPS metrics ───────────────────────────────────────────────────
    metrics.update(_compute_gps_metrics(gps_df))

    # ── Data quality score ────────────────────────────────────────────
    metrics["data_quality_score"] = _compute_quality_score(metrics)

    logger.info(
        f"Metrics: duration={metrics.get('duration_s', 0):.1f}s, "
        f"freq={metrics.get('actual_frequency_hz', 0):.2f}Hz, "
        f"loss={metrics.get('packet_loss_estimate', 0):.1f}%, "
        f"quality={metrics.get('data_quality_score', 0):.1f}/100"
    )
    return metrics


# ── Private helpers ──────────────────────────────────────────────────

def _get_session_id(df: pd.DataFrame) -> str:
    if df.empty or "session_id" not in df.columns:
        return "unknown"
    ids = df["session_id"].dropna().unique()
    return str(ids[0]) if len(ids) > 0 else "unknown"


def _compute_time_metrics(imu_df: pd.DataFrame) -> dict[str, Any]:
    """Return session timing metrics.

    - start_time_ms / end_time_ms use received_at (Unix epoch, Android wall clock)
      when available, so they display as real dates in the report.
    - duration_s is computed from device timestamps (dtr + idx*t) because those
      are the precise intra-session timing — received_at is per-packet only.
    """
    if imu_df.empty or "timestamp_ms" not in imu_df.columns:
        return {"duration_s": 0.0, "start_time_ms": 0, "end_time_ms": 0}

    ts = imu_df["timestamp_ms"].dropna()
    if len(ts) < 2:
        return {"duration_s": 0.0, "start_time_ms": 0, "end_time_ms": 0}

    duration_s = (int(ts.max()) - int(ts.min())) / 1000.0

    # Prefer received_at_ms (Unix epoch) for display timestamps
    if "received_at_ms" in imu_df.columns:
        rts = imu_df["received_at_ms"].dropna()
        rts = rts[rts > 0]
        if len(rts) >= 2:
            return {
                "duration_s":    duration_s,
                "start_time_ms": int(rts.min()),
                "end_time_ms":   int(rts.max()),
            }

    # Fallback to device timer (will display as 1970-era — not wall clock)
    return {
        "duration_s":    duration_s,
        "start_time_ms": int(ts.min()),
        "end_time_ms":   int(ts.max()),
    }


def _compute_sample_metrics(imu_df: pd.DataFrame) -> dict[str, Any]:
    if imu_df.empty:
        return {"sample_count": 0, "actual_frequency_hz": 0.0, "packet_count": 0}

    # Count non-duplicate samples
    valid = imu_df[~imu_df.get("is_duplicate", pd.Series([False]*len(imu_df)))]
    sample_count = len(valid)

    # Actual frequency
    ts = valid["timestamp_ms"].dropna()
    if len(ts) >= 2:
        duration_s = (ts.max() - ts.min()) / 1000.0
        actual_freq = sample_count / duration_s if duration_s > 0 else 0.0
    else:
        actual_freq = 0.0

    # Unique packet count
    packet_count = int(imu_df["packet_index"].nunique()) if "packet_index" in imu_df.columns else 0

    return {
        "sample_count":        sample_count,
        "actual_frequency_hz": round(actual_freq, 3),
        "packet_count":        packet_count,
    }


def _compute_packet_loss(imu_df: pd.DataFrame) -> float:
    """
    Estimate packet loss percentage by detecting gaps larger than the
    observed median sample period.

    The threshold is derived from the data itself (2× median delta), so this
    works across 25/50/100 Hz captures without re-tuning constants.
    """
    if imu_df.empty or "timestamp_ms" not in imu_df.columns:
        return 0.0

    valid = imu_df[~imu_df.get("is_duplicate", pd.Series([False]*len(imu_df)))].copy()
    valid = valid.sort_values("timestamp_ms")

    ts = valid["timestamp_ms"].values.astype(float)
    if len(ts) < 2:
        return 0.0

    diffs = np.diff(ts)
    diffs = diffs[diffs > 0]
    if len(diffs) == 0:
        return 0.0

    median_period_ms = float(np.median(diffs))
    if median_period_ms <= 0:
        return 0.0

    # Tolerate 2× median before declaring a gap
    gap_threshold = max(median_period_ms * 2.0, 5.0)
    gap_mask = diffs > gap_threshold

    if not gap_mask.any():
        return 0.0

    # Estimate missing samples in each gap, relative to observed median period
    gap_sizes = diffs[gap_mask]
    missing_samples = int(np.sum(gap_sizes / median_period_ms - 1).clip(min=0))
    total_expected = len(ts) + missing_samples

    if total_expected == 0:
        return 0.0

    loss_pct = missing_samples / total_expected * 100.0
    logger.debug(
        f"Packet loss: median_period={median_period_ms:.1f}ms, "
        f"threshold={gap_threshold:.1f}ms, {missing_samples} missing samples, "
        f"{gap_mask.sum()} gaps, loss={loss_pct:.1f}%"
    )
    return round(loss_pct, 2)


def _compute_imu_metrics(imu_df: pd.DataFrame) -> dict[str, Any]:
    """Compute accelerometer and gyroscope statistical metrics."""
    result: dict[str, Any] = {
        "acc_norm_mean": 0.0, "acc_norm_std": 0.0, "acc_norm_max": 0.0,
        "gyro_norm_mean": 0.0, "gyro_norm_std": 0.0, "gyro_norm_max": 0.0,
    }

    if imu_df.empty:
        return result

    # Accelerometer norm (g)
    if all(c in imu_df.columns for c in ("ax_g", "ay_g", "az_g")):
        acc_norm = np.sqrt(
            imu_df["ax_g"]**2 + imu_df["ay_g"]**2 + imu_df["az_g"]**2
        ).dropna()
        if len(acc_norm) > 0:
            result["acc_norm_mean"] = round(float(acc_norm.mean()), 4)
            result["acc_norm_std"]  = round(float(acc_norm.std()),  4)
            result["acc_norm_max"]  = round(float(acc_norm.max()),  4)

    # Gyroscope norm (deg/s)
    if all(c in imu_df.columns for c in ("gx_dps", "gy_dps", "gz_dps")):
        gyro_norm = np.sqrt(
            imu_df["gx_dps"]**2 + imu_df["gy_dps"]**2 + imu_df["gz_dps"]**2
        ).dropna()
        if len(gyro_norm) > 0:
            result["gyro_norm_mean"] = round(float(gyro_norm.mean()), 4)
            result["gyro_norm_std"]  = round(float(gyro_norm.std()),  4)
            result["gyro_norm_max"]  = round(float(gyro_norm.max()),  4)

    return result


def _compute_hr_metrics(imu_df: pd.DataFrame) -> dict[str, Any]:
    """Compute heart rate statistics."""
    result: dict[str, Any] = {
        "hr_mean": None, "hr_min": None, "hr_max": None,
        "hr_std": None,  "hr_samples": 0,
    }

    if imu_df.empty or "hr_bpm" not in imu_df.columns:
        return result

    hr = imu_df["hr_bpm"].dropna()
    hr = hr[hr > 0]  # Remove zeros that weren't converted to NaN
    if len(hr) == 0:
        return result

    result["hr_samples"] = int(len(hr))
    result["hr_mean"]    = round(float(hr.mean()), 1)
    result["hr_min"]     = round(float(hr.min()),  1)
    result["hr_max"]     = round(float(hr.max()),  1)
    result["hr_std"]     = round(float(hr.std()),  2)

    return result


def _compute_gps_metrics(gps_df: pd.DataFrame) -> dict[str, Any]:
    """Compute GPS-derived metrics: distance, speed, altitude."""
    result: dict[str, Any] = {
        "gps_sample_count": 0,
        "gps_distance_m":   0.0,
        "gps_max_speed_ms": 0.0,
        "altitude_gain_m":  0.0,
        "altitude_loss_m":  0.0,
    }

    if gps_df.empty:
        return result

    valid = gps_df[~gps_df.get("is_duplicate", pd.Series([False]*len(gps_df)))].copy()
    valid = valid.sort_values("timestamp_ms")
    result["gps_sample_count"] = len(valid)

    # Distance from Haversine
    if len(valid) >= 2 and "lat_deg" in valid.columns and "lon_deg" in valid.columns:
        total_dist = 0.0
        lats = valid["lat_deg"].values
        lons = valid["lon_deg"].values
        for i in range(1, len(lats)):
            d = _haversine(lats[i-1], lons[i-1], lats[i], lons[i])
            total_dist += d
        result["gps_distance_m"] = round(total_dist, 1)

    # Max speed
    if "speed_ms" in valid.columns:
        spd = valid["speed_ms"].dropna()
        if len(spd) > 0:
            result["gps_max_speed_ms"] = round(float(spd.max()), 2)

    # Altitude gain/loss
    if "alt_m" in valid.columns:
        alt = valid["alt_m"].dropna()
        if len(alt) >= 2:
            diff = np.diff(alt.values)
            result["altitude_gain_m"] = round(float(diff[diff > 0].sum()), 1)
            result["altitude_loss_m"] = round(float(abs(diff[diff < 0].sum())), 1)

    return result


def _compute_quality_score(metrics: dict[str, Any]) -> float:
    """
    Compute a composite data quality score from 0 (poor) to 100 (excellent).

    Factors:
    - Frequency accuracy (actual vs nominal)
    - Packet loss rate
    - Sample count (duration)
    """
    score = 100.0

    # Penalize for low frequency
    actual_freq = metrics.get("actual_frequency_hz", 0.0)
    if actual_freq > 0:
        freq_ratio = min(actual_freq / NOMINAL_FREQUENCY_HZ, 1.0)
        score -= (1.0 - freq_ratio) * 30  # Max -30 pts for freq issues

    # Penalize for packet loss
    loss = metrics.get("packet_loss_estimate", 0.0)
    score -= min(loss * 2, 40)  # Max -40 pts for packet loss

    # Penalize for very short sessions (graduated penalty)
    duration = metrics.get("duration_s", 0.0)
    sample_count = metrics.get("sample_count", 0)
    if sample_count < 25:          # Less than 1 second of data
        score -= 30
    elif duration < 5:
        score -= 20
    elif duration < 30:
        score -= 10

    # Penalize for zero GPS
    if metrics.get("gps_sample_count", 0) == 0:
        score -= 10

    return round(max(score, 0.0), 1)


def _haversine(lat1_deg: float, lon1_deg: float,
               lat2_deg: float, lon2_deg: float) -> float:
    """
    Compute the great-circle distance (meters) between two GPS points.

    Args:
        lat1_deg, lon1_deg: First point (decimal degrees)
        lat2_deg, lon2_deg: Second point (decimal degrees)

    Returns:
        Distance in meters
    """
    lat1, lon1 = math.radians(lat1_deg), math.radians(lon1_deg)
    lat2, lon2 = math.radians(lat2_deg), math.radians(lon2_deg)

    dlat = lat2 - lat1
    dlon = lon2 - lon1

    a = math.sin(dlat / 2)**2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2)**2
    c = 2 * math.asin(math.sqrt(a))

    return EARTH_RADIUS_M * c
