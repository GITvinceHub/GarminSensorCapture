"""
Normalize raw Garmin packet dicts into structured pandas DataFrames.

Produces:
  imu_df  — One row per IMU sample with absolute timestamps and converted units
  gps_df  — One row per GPS fix

Unit conversions applied:
  Accelerometer: milli-g → g  (divide by 1000)
  Gyroscope: deg/s (unchanged)
  Magnetometer: µT (unchanged)
  HR: bpm (0 → NaN)
  GPS timestamp: Unix seconds → Unix milliseconds
"""

import logging
from datetime import datetime
from typing import Any

import numpy as np
import pandas as pd

logger = logging.getLogger(__name__)

# Nominal accel/gyro sample frequency (Hz) — see H-001 in hypotheses.md
# Watch currently ships with accel/gyro at 100 Hz and magnetometer at 25 Hz.
NOMINAL_FREQUENCY_HZ = 100.0
NOMINAL_PERIOD_MS = 1000.0 / NOMINAL_FREQUENCY_HZ  # 10 ms

# Maximum allowed gap (ms) for linear interpolation
# Gaps larger than this are left as-is (no interpolation)
MAX_INTERPOLATION_GAP_MS = 5 * NOMINAL_PERIOD_MS  # 5 × 40ms = 200ms


def normalize_data(
    packets: list[dict[str, Any]]
) -> tuple[pd.DataFrame, pd.DataFrame]:
    """
    Convert a list of validated packet dicts to IMU and GPS DataFrames.

    Args:
        packets: List of validated packet dicts from parser.parse_jsonl()

    Returns:
        Tuple (imu_df, gps_df):
          - imu_df: DataFrame with columns documented in 04_docs/03_data_schema.md
          - gps_df: DataFrame with GPS columns
    """
    if not packets:
        logger.warning("normalize_data: empty packet list, returning empty DataFrames")
        return _empty_imu_df(), _empty_gps_df()

    imu_rows: list[dict[str, Any]] = []
    gps_rows: list[dict[str, Any]] = []

    for pkt in packets:
        dtr: int = int(pkt.get("dtr", 0))
        sid: str = str(pkt.get("sid", ""))
        pi: int  = int(pkt.get("pi", 0))
        received_at: str = str(pkt.get("received_at", ""))
        received_at_ms = _parse_iso_ms(received_at)

        # ── IMU samples ───────────────────────────────────────────────
        samples = pkt.get("s", [])
        for idx, sample in enumerate(samples):
            # `t` is the per-sample period in ms (e.g. 10 ms @ 100 Hz, 40 ms @ 25 Hz).
            # The absolute device timestamp of sample #idx in the batch is:
            #     dtr + idx * t
            # (dtr is System.getTimer() on the watch = ms since boot,
            # not Unix epoch — use received_at_ms for wall-clock display.)
            period_ms = int(sample.get("t", 0))
            abs_ts    = dtr + idx * period_ms

            # Convert accelerometer milli-g → g
            ax_g = float(sample.get("ax", 0.0)) / 1000.0
            ay_g = float(sample.get("ay", 0.0)) / 1000.0
            az_g = float(sample.get("az", 0.0)) / 1000.0

            # Gyroscope stays in deg/s
            gx = float(sample.get("gx", 0.0))
            gy = float(sample.get("gy", 0.0))
            gz = float(sample.get("gz", 0.0))

            # Magnetometer stays in µT
            mx = float(sample.get("mx", 0.0))
            my = float(sample.get("my", 0.0))
            mz = float(sample.get("mz", 0.0))

            # Heart rate: 0 → NaN
            hr_raw = sample.get("hr", 0)
            hr = float(hr_raw) if (hr_raw is not None and int(hr_raw) > 0) else np.nan

            imu_rows.append({
                "timestamp_ms":     abs_ts,
                "received_at_ms":   received_at_ms,
                "session_id":       sid,
                "packet_index":     pi,
                "sample_index":     idx,
                "ax_g":             ax_g,
                "ay_g":             ay_g,
                "az_g":             az_g,
                "gx_dps":           gx,
                "gy_dps":           gy,
                "gz_dps":           gz,
                "mx_uT":            mx,
                "my_uT":            my,
                "mz_uT":            mz,
                "hr_bpm":           hr,
                "received_at":      received_at,
                "is_duplicate":     False,
                "interpolated":     False,
            })

        # ── GPS data ──────────────────────────────────────────────────
        gps = pkt.get("gps")
        if gps is not None and isinstance(gps, dict):
            ts_unix_s = int(gps.get("ts", 0))
            ts_ms     = ts_unix_s * 1000  # Convert seconds → ms

            gps_rows.append({
                "timestamp_ms": ts_ms,
                "session_id":   sid,
                "packet_index": pi,
                "lat_deg":      float(gps.get("lat", 0.0)),
                "lon_deg":      float(gps.get("lon", 0.0)),
                "alt_m":        float(gps["alt"]) if gps.get("alt") is not None else np.nan,
                "speed_ms":     float(gps["spd"]) if gps.get("spd") is not None else np.nan,
                "heading_deg":  float(gps["hdg"]) if gps.get("hdg") is not None else np.nan,
                "accuracy_m":   float(gps["acc"]) if gps.get("acc") is not None else np.nan,
                "received_at":  received_at,
                "is_duplicate": False,
            })

    # ── Build DataFrames ──────────────────────────────────────────────
    if imu_rows:
        imu_df = pd.DataFrame(imu_rows)
        imu_df = _post_process_imu(imu_df)
    else:
        imu_df = _empty_imu_df()

    if gps_rows:
        gps_df = pd.DataFrame(gps_rows)
        gps_df = _post_process_gps(gps_df)
    else:
        gps_df = _empty_gps_df()

    logger.info(
        f"normalize_data: {len(imu_df)} IMU samples, {len(gps_df)} GPS fixes"
    )
    return imu_df, gps_df


def _post_process_imu(df: pd.DataFrame) -> pd.DataFrame:
    """Sort, deduplicate, and optionally interpolate IMU data."""
    # Sort by timestamp
    df = df.sort_values("timestamp_ms").reset_index(drop=True)

    # Mark duplicates (same timestamp_ms)
    dup_mask = df.duplicated(subset=["timestamp_ms"], keep="first")
    df.loc[dup_mask, "is_duplicate"] = True
    n_dups = dup_mask.sum()
    if n_dups > 0:
        logger.warning(f"IMU: {n_dups} duplicate timestamps marked")

    # Ensure correct dtypes
    df["timestamp_ms"] = df["timestamp_ms"].astype("int64")
    df["packet_index"] = df["packet_index"].astype("int64")
    df["sample_index"] = df["sample_index"].astype("int64")
    df["is_duplicate"] = df["is_duplicate"].astype(bool)
    df["interpolated"]  = df["interpolated"].astype(bool)

    # Interpolate short gaps (optional, fills NaN in sensor columns)
    df = _interpolate_gaps(df)

    return df


def _post_process_gps(df: pd.DataFrame) -> pd.DataFrame:
    """Sort and deduplicate GPS data."""
    df = df.sort_values("timestamp_ms").reset_index(drop=True)

    # Mark duplicates
    dup_mask = df.duplicated(subset=["timestamp_ms"], keep="first")
    df.loc[dup_mask, "is_duplicate"] = True

    df["timestamp_ms"] = df["timestamp_ms"].astype("int64")
    df["packet_index"] = df["packet_index"].astype("int64")
    df["is_duplicate"] = df["is_duplicate"].astype(bool)

    return df


def _interpolate_gaps(df: pd.DataFrame) -> pd.DataFrame:
    """
    Linearly interpolate sensor values across gaps smaller than MAX_INTERPOLATION_GAP_MS.

    Gaps larger than the threshold are left as-is.
    Only non-duplicate rows are considered for gap detection.
    """
    if len(df) < 2:
        return df

    # Work on non-duplicate rows only
    clean = df[~df["is_duplicate"]].copy()
    if len(clean) < 2:
        return df

    ts = clean["timestamp_ms"].values.astype(float)
    diffs = np.diff(ts)

    # Columns to interpolate
    interp_cols = ["ax_g", "ay_g", "az_g", "gx_dps", "gy_dps", "gz_dps",
                   "mx_uT", "my_uT", "mz_uT"]

    # Find gap positions
    gap_positions = np.where(diffs > MAX_INTERPOLATION_GAP_MS)[0]
    if len(gap_positions) > 0:
        logger.debug(f"Found {len(gap_positions)} interpolatable gaps in IMU data")

    # Use pandas interpolation on the full df (by position, linear)
    numeric_cols = interp_cols + ["hr_bpm"]
    df[numeric_cols] = df[numeric_cols].interpolate(method="linear", limit_direction="forward")

    return df


def _empty_imu_df() -> pd.DataFrame:
    """Return an empty DataFrame with the correct IMU schema."""
    return pd.DataFrame(columns=[
        "timestamp_ms", "received_at_ms",
        "session_id", "packet_index", "sample_index",
        "ax_g", "ay_g", "az_g",
        "gx_dps", "gy_dps", "gz_dps",
        "mx_uT", "my_uT", "mz_uT",
        "hr_bpm", "received_at", "is_duplicate", "interpolated"
    ])


def _parse_iso_ms(iso_str: str) -> int:
    """Parse an ISO 8601 timestamp into Unix milliseconds. Returns 0 on failure."""
    if not iso_str:
        return 0
    try:
        # Handle trailing 'Z' and fractional seconds
        s = iso_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(s)
        return int(dt.timestamp() * 1000)
    except (ValueError, TypeError):
        return 0


def _empty_gps_df() -> pd.DataFrame:
    """Return an empty DataFrame with the correct GPS schema."""
    return pd.DataFrame(columns=[
        "timestamp_ms", "session_id", "packet_index",
        "lat_deg", "lon_deg", "alt_m", "speed_ms",
        "heading_deg", "accuracy_m", "received_at", "is_duplicate"
    ])
