"""
Generate output reports from analysis results.

Writes:
  summary.txt   — Human-readable session report
  imu_data.csv  — Full IMU DataFrame as CSV
  gps_data.csv  — Full GPS DataFrame as CSV
  metrics.json  — Metrics dictionary as JSON
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import pandas as pd

logger = logging.getLogger(__name__)


def generate_report(
    packets: list[dict[str, Any]],
    imu_df: pd.DataFrame,
    gps_df: pd.DataFrame,
    metrics: dict[str, Any],
    output_dir: Path
) -> dict[str, Path]:
    """
    Write all output files to output_dir.

    Args:
        packets:    Raw packet list from parser
        imu_df:     Normalized IMU DataFrame
        gps_df:     Normalized GPS DataFrame
        metrics:    Metrics dictionary from compute_metrics()
        output_dir: Directory to write files

    Returns:
        Dictionary mapping output type to file path
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    written: dict[str, Path] = {}

    # ── metrics.json ──────────────────────────────────────────────────
    metrics_path = output_dir / "metrics.json"
    try:
        with open(metrics_path, "w", encoding="utf-8") as fh:
            json.dump(metrics, fh, indent=2, default=_json_default)
        written["metrics"] = metrics_path
        logger.debug(f"Written: {metrics_path.name}")
    except Exception as exc:
        logger.error(f"Failed to write metrics.json: {exc}")

    # ── imu_data.csv ──────────────────────────────────────────────────
    imu_path = output_dir / "imu_data.csv"
    try:
        if not imu_df.empty:
            imu_df.to_csv(imu_path, index=False, encoding="utf-8")
            logger.debug(f"Written: {imu_path.name} ({len(imu_df)} rows)")
        else:
            # Write empty CSV with header
            pd.DataFrame(columns=imu_df.columns if hasattr(imu_df, "columns") else []).to_csv(
                imu_path, index=False
            )
        written["imu_csv"] = imu_path
    except Exception as exc:
        logger.error(f"Failed to write imu_data.csv: {exc}")

    # ── gps_data.csv ──────────────────────────────────────────────────
    gps_path = output_dir / "gps_data.csv"
    try:
        if not gps_df.empty:
            gps_df.to_csv(gps_path, index=False, encoding="utf-8")
            logger.debug(f"Written: {gps_path.name} ({len(gps_df)} rows)")
        else:
            pd.DataFrame(columns=gps_df.columns if hasattr(gps_df, "columns") else []).to_csv(
                gps_path, index=False
            )
        written["gps_csv"] = gps_path
    except Exception as exc:
        logger.error(f"Failed to write gps_data.csv: {exc}")

    # ── summary.txt ───────────────────────────────────────────────────
    summary_path = output_dir / "summary.txt"
    try:
        summary = _build_summary(packets, imu_df, gps_df, metrics)
        with open(summary_path, "w", encoding="utf-8") as fh:
            fh.write(summary)
        written["summary"] = summary_path
        logger.debug(f"Written: {summary_path.name}")
    except Exception as exc:
        logger.error(f"Failed to write summary.txt: {exc}")

    logger.info(
        f"Report written: {len(written)} files in {output_dir}"
    )
    return written


def _build_summary(
    packets: list[dict[str, Any]],
    imu_df: pd.DataFrame,
    gps_df: pd.DataFrame,
    metrics: dict[str, Any]
) -> str:
    """Build a human-readable summary report string."""
    now = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

    lines = [
        "=" * 60,
        "  Garmin Sensor Capture — Session Report",
        "=" * 60,
        f"  Generated:  {now}",
        "",
        "── Session Info ─────────────────────────────────────────",
        f"  Session ID    : {metrics.get('session_id', 'unknown')}",
        f"  Duration      : {metrics.get('duration_s', 0):.2f} s",
        f"  Start time    : {_format_ts(metrics.get('start_time_ms'))}",
        f"  End time      : {_format_ts(metrics.get('end_time_ms'))}",
        "",
        "── IMU Data ─────────────────────────────────────────────",
        f"  Packets       : {metrics.get('packet_count', 0):,}",
        f"  Samples       : {metrics.get('sample_count', 0):,}",
        f"  Frequency     : {metrics.get('actual_frequency_hz', 0):.3f} Hz"
        f"  (nominal: {metrics.get('nominal_frequency_hz', 25):.0f} Hz)",
        f"  Packet loss   : {metrics.get('packet_loss_estimate', 0):.2f} %",
        "",
        "── Accelerometer ────────────────────────────────────────",
        f"  Norm mean     : {_fmt(metrics.get('acc_norm_mean'))} g",
        f"  Norm std      : {_fmt(metrics.get('acc_norm_std'))}  g",
        f"  Norm max      : {_fmt(metrics.get('acc_norm_max'))}  g",
        "",
        "── Gyroscope ────────────────────────────────────────────",
        f"  Norm mean     : {_fmt(metrics.get('gyro_norm_mean'))} °/s",
        f"  Norm std      : {_fmt(metrics.get('gyro_norm_std'))}  °/s",
        f"  Norm max      : {_fmt(metrics.get('gyro_norm_max'))}  °/s",
        "",
        "── Heart Rate ───────────────────────────────────────────",
        f"  Samples       : {metrics.get('hr_samples', 0):,}",
        f"  Mean          : {_fmt(metrics.get('hr_mean'))} bpm",
        f"  Min           : {_fmt(metrics.get('hr_min'))} bpm",
        f"  Max           : {_fmt(metrics.get('hr_max'))} bpm",
        f"  Std dev       : {_fmt(metrics.get('hr_std'))} bpm",
        "",
        "── GPS ──────────────────────────────────────────────────",
        f"  GPS fixes     : {metrics.get('gps_sample_count', 0):,}",
        f"  Total distance: {metrics.get('gps_distance_m', 0):.1f} m",
        f"  Max speed     : {metrics.get('gps_max_speed_ms', 0):.2f} m/s"
        f"  ({metrics.get('gps_max_speed_ms', 0) * 3.6:.1f} km/h)",
        f"  Altitude gain : +{metrics.get('altitude_gain_m', 0):.1f} m",
        f"  Altitude loss : -{metrics.get('altitude_loss_m', 0):.1f} m",
        "",
        "── Quality ──────────────────────────────────────────────",
        f"  Quality score : {metrics.get('data_quality_score', 0):.1f} / 100",
        "",
        "── Files ────────────────────────────────────────────────",
        "  imu_data.csv     : IMU sensor table",
        "  gps_data.csv     : GPS data table",
        "  metrics.json     : Numeric metrics (machine-readable)",
        "  *.png            : Visualization plots",
        "",
        "=" * 60,
    ]

    # Append raw packet stats if available
    if packets:
        session_ids = list(dict.fromkeys(p.get("sid", "") for p in packets if p.get("sid")))
        lines += [
            "── Raw Packet Stats ─────────────────────────────────────",
            f"  Total packets parsed   : {len(packets):,}",
            f"  Session IDs found      : {len(session_ids)}",
        ]
        for sid in session_ids:
            count = sum(1 for p in packets if p.get("sid") == sid)
            lines.append(f"    • {sid}: {count:,} packets")
        lines.append("=" * 60)

    return "\n".join(lines) + "\n"


def _fmt(value: Any, decimals: int = 4) -> str:
    """Format a numeric value or return '-' if None."""
    if value is None:
        return "-"
    try:
        return f"{float(value):.{decimals}f}"
    except (TypeError, ValueError):
        return str(value)


def _format_ts(ts_ms: Any) -> str:
    """Format a Unix millisecond timestamp as human-readable string."""
    if ts_ms is None or ts_ms == 0:
        return "-"
    try:
        dt = datetime.fromtimestamp(int(ts_ms) / 1000.0, tz=timezone.utc)
        return dt.strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        return str(ts_ms)


def _json_default(obj: Any) -> Any:
    """JSON serializer for non-standard types."""
    if isinstance(obj, (float,)):
        # Handle NaN / Inf
        if obj != obj:  # NaN check
            return None
        if obj == float("inf") or obj == float("-inf"):
            return None
        return obj
    if hasattr(obj, "item"):  # numpy scalar
        return obj.item()
    raise TypeError(f"Object of type {type(obj).__name__} is not JSON serializable")
