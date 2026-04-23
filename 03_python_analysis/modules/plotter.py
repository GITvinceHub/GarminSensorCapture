"""
Generate visualization plots from normalized sensor data.

Output files (PNG, DPI 150):
  accelerometer_xyz.png  — ax, ay, az over time
  gyroscope_xyz.png      — gx, gy, gz over time
  heart_rate.png         — heart rate time series
  gps_track.png          — lat/lon scatter colored by speed
  altitude_profile.png   — altitude vs time
  sensor_overview.png    — combined multi-panel dashboard
"""

import logging
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

logger = logging.getLogger(__name__)

# Plot settings
DPI = 150
FIGURE_SIZE_WIDE = (12, 4)
FIGURE_SIZE_SQUARE = (8, 8)
FIGURE_SIZE_OVERVIEW = (14, 10)


def generate_plots(
    imu_df: pd.DataFrame,
    gps_df: pd.DataFrame,
    metrics: dict[str, Any],
    output_dir: Path
) -> list[Path]:
    """
    Generate all visualization plots and save to output_dir.

    Args:
        imu_df:     Normalized IMU DataFrame
        gps_df:     Normalized GPS DataFrame
        metrics:    Metrics dictionary from compute_metrics()
        output_dir: Directory to save PNG files

    Returns:
        List of paths to generated PNG files
    """
    # Import matplotlib lazily (avoids issues in headless environments)
    try:
        import matplotlib
        matplotlib.use("Agg")  # Non-interactive backend for file output
        import matplotlib.pyplot as plt
        import matplotlib.cm as cm
    except ImportError as e:
        logger.error(f"matplotlib not available: {e}")
        return []

    output_dir = Path(output_dir)
    generated: list[Path] = []

    # Prepare time axis in seconds (relative to session start)
    t_imu = _get_relative_time_s(imu_df)
    t_gps = _get_relative_time_s(gps_df)

    # ── Accelerometer ─────────────────────────────────────────────────
    if not imu_df.empty and all(c in imu_df.columns for c in ("ax_g", "ay_g", "az_g")):
        fig, ax = plt.subplots(figsize=FIGURE_SIZE_WIDE)
        ax.plot(t_imu, imu_df["ax_g"], "r-", linewidth=0.5, alpha=0.8, label="ax (g)")
        ax.plot(t_imu, imu_df["ay_g"], "g-", linewidth=0.5, alpha=0.8, label="ay (g)")
        ax.plot(t_imu, imu_df["az_g"], "b-", linewidth=0.5, alpha=0.8, label="az (g)")
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Acceleration (g)")
        ax.set_title("Accelerometer — X / Y / Z")
        ax.legend(loc="upper right", fontsize=8)
        ax.grid(True, alpha=0.3)
        fig.tight_layout()
        path = output_dir / "accelerometer_xyz.png"
        fig.savefig(path, dpi=DPI, bbox_inches="tight")
        plt.close(fig)
        generated.append(path)
        logger.debug(f"Saved {path.name}")

    # ── Gyroscope ─────────────────────────────────────────────────────
    if not imu_df.empty and all(c in imu_df.columns for c in ("gx_dps", "gy_dps", "gz_dps")):
        fig, ax = plt.subplots(figsize=FIGURE_SIZE_WIDE)
        ax.plot(t_imu, imu_df["gx_dps"], "r-", linewidth=0.5, alpha=0.8, label="gx (°/s)")
        ax.plot(t_imu, imu_df["gy_dps"], "g-", linewidth=0.5, alpha=0.8, label="gy (°/s)")
        ax.plot(t_imu, imu_df["gz_dps"], "b-", linewidth=0.5, alpha=0.8, label="gz (°/s)")
        ax.set_xlabel("Time (s)")
        ax.set_ylabel("Angular velocity (°/s)")
        ax.set_title("Gyroscope — X / Y / Z")
        ax.legend(loc="upper right", fontsize=8)
        ax.grid(True, alpha=0.3)
        fig.tight_layout()
        path = output_dir / "gyroscope_xyz.png"
        fig.savefig(path, dpi=DPI, bbox_inches="tight")
        plt.close(fig)
        generated.append(path)

    # ── Heart rate ────────────────────────────────────────────────────
    if not imu_df.empty and "hr_bpm" in imu_df.columns:
        hr_valid = imu_df["hr_bpm"].dropna()
        if len(hr_valid) > 0:
            hr_times = t_imu[imu_df["hr_bpm"].notna()]
            fig, ax = plt.subplots(figsize=FIGURE_SIZE_WIDE)
            ax.plot(hr_times, hr_valid.values, "r-", linewidth=1.5, label="HR (bpm)")
            if metrics.get("hr_mean") is not None:
                ax.axhline(
                    metrics["hr_mean"], color="darkred",
                    linestyle="--", linewidth=1, alpha=0.7,
                    label=f"Mean: {metrics['hr_mean']:.0f} bpm"
                )
            ax.set_xlabel("Time (s)")
            ax.set_ylabel("Heart Rate (bpm)")
            ax.set_title("Heart Rate")
            ax.legend(loc="upper right", fontsize=9)
            ax.set_ylim(bottom=40)
            ax.grid(True, alpha=0.3)
            fig.tight_layout()
            path = output_dir / "heart_rate.png"
            fig.savefig(path, dpi=DPI, bbox_inches="tight")
            plt.close(fig)
            generated.append(path)

    # ── GPS Track ─────────────────────────────────────────────────────
    if not gps_df.empty and "lat_deg" in gps_df.columns:
        fig, ax = plt.subplots(figsize=FIGURE_SIZE_SQUARE)

        if "speed_ms" in gps_df.columns and gps_df["speed_ms"].notna().any():
            spd = gps_df["speed_ms"].fillna(0).values
            scatter = ax.scatter(
                gps_df["lon_deg"], gps_df["lat_deg"],
                c=spd, cmap="plasma",
                s=10, alpha=0.8, linewidths=0
            )
            cbar = fig.colorbar(scatter, ax=ax)
            cbar.set_label("Speed (m/s)", fontsize=9)
        else:
            ax.plot(gps_df["lon_deg"], gps_df["lat_deg"], "b.-", markersize=3, linewidth=0.5)

        # Mark start and end
        if len(gps_df) > 0:
            ax.plot(gps_df["lon_deg"].iloc[0],  gps_df["lat_deg"].iloc[0],
                    "go", markersize=10, label="Start", zorder=5)
            ax.plot(gps_df["lon_deg"].iloc[-1], gps_df["lat_deg"].iloc[-1],
                    "rs", markersize=10, label="End", zorder=5)

        ax.set_xlabel("Longitude (°)")
        ax.set_ylabel("Latitude (°)")
        ax.set_title("GPS Track")
        ax.legend(loc="best", fontsize=9)
        ax.grid(True, alpha=0.3)
        _equal_aspect_geo(ax, gps_df)
        fig.tight_layout()
        path = output_dir / "gps_track.png"
        fig.savefig(path, dpi=DPI, bbox_inches="tight")
        plt.close(fig)
        generated.append(path)

    # ── Altitude Profile ──────────────────────────────────────────────
    if not gps_df.empty and "alt_m" in gps_df.columns:
        alt_valid = gps_df["alt_m"].dropna()
        if len(alt_valid) > 0:
            alt_times = t_gps[gps_df["alt_m"].notna()]
            fig, ax = plt.subplots(figsize=FIGURE_SIZE_WIDE)
            ax.fill_between(alt_times, alt_valid.values,
                            alpha=0.3, color="green", label="Altitude")
            ax.plot(alt_times, alt_valid.values, "g-", linewidth=1.5)
            gain = metrics.get("altitude_gain_m", 0)
            loss = metrics.get("altitude_loss_m", 0)
            ax.set_title(f"Altitude Profile  (+{gain:.0f}m / -{loss:.0f}m)")
            ax.set_xlabel("Time (s)")
            ax.set_ylabel("Altitude MSL (m)")
            ax.grid(True, alpha=0.3)
            fig.tight_layout()
            path = output_dir / "altitude_profile.png"
            fig.savefig(path, dpi=DPI, bbox_inches="tight")
            plt.close(fig)
            generated.append(path)

    # ── Sensor Overview (combined dashboard) ─────────────────────────
    path = _generate_overview(imu_df, gps_df, metrics, t_imu, t_gps, output_dir, plt)
    if path:
        generated.append(path)

    logger.info(f"Generated {len(generated)} plots in {output_dir}")
    return generated


def _generate_overview(
    imu_df: pd.DataFrame,
    gps_df: pd.DataFrame,
    metrics: dict[str, Any],
    t_imu: np.ndarray,
    t_gps: np.ndarray,
    output_dir: Path,
    plt: Any
) -> Path | None:
    """Generate a combined multi-panel dashboard figure."""
    try:
        n_rows = 3
        n_cols = 2
        fig, axes = plt.subplots(n_rows, n_cols, figsize=FIGURE_SIZE_OVERVIEW)
        fig.suptitle(
            f"Sensor Overview — Session: {metrics.get('session_id', 'unknown')}  "
            f"Duration: {metrics.get('duration_s', 0):.0f}s  "
            f"Quality: {metrics.get('data_quality_score', 0):.0f}/100",
            fontsize=11, y=0.98
        )

        # [0,0] Accelerometer norm
        ax = axes[0, 0]
        if not imu_df.empty and all(c in imu_df.columns for c in ("ax_g","ay_g","az_g")):
            norm = np.sqrt(imu_df["ax_g"]**2 + imu_df["ay_g"]**2 + imu_df["az_g"]**2)
            ax.plot(t_imu, norm, "b-", linewidth=0.5, alpha=0.8)
            ax.axhline(1.0, color="gray", linestyle="--", linewidth=0.8, alpha=0.5)
        ax.set_title("Accel Norm (g)", fontsize=9)
        ax.set_xlabel("t (s)", fontsize=8)
        ax.grid(True, alpha=0.3)

        # [0,1] Gyroscope norm
        ax = axes[0, 1]
        if not imu_df.empty and all(c in imu_df.columns for c in ("gx_dps","gy_dps","gz_dps")):
            gnorm = np.sqrt(imu_df["gx_dps"]**2 + imu_df["gy_dps"]**2 + imu_df["gz_dps"]**2)
            ax.plot(t_imu, gnorm, "r-", linewidth=0.5, alpha=0.8)
        ax.set_title("Gyro Norm (°/s)", fontsize=9)
        ax.set_xlabel("t (s)", fontsize=8)
        ax.grid(True, alpha=0.3)

        # [1,0] Heart rate
        ax = axes[1, 0]
        if not imu_df.empty and "hr_bpm" in imu_df.columns:
            hr_v = imu_df["hr_bpm"].dropna()
            if len(hr_v) > 0:
                ax.plot(t_imu[imu_df["hr_bpm"].notna()], hr_v.values, "r-", linewidth=1)
        ax.set_title("Heart Rate (bpm)", fontsize=9)
        ax.set_xlabel("t (s)", fontsize=8)
        ax.set_ylim(bottom=40)
        ax.grid(True, alpha=0.3)

        # [1,1] GPS track
        ax = axes[1, 1]
        if not gps_df.empty and "lat_deg" in gps_df.columns:
            ax.plot(gps_df["lon_deg"], gps_df["lat_deg"], "b.-", markersize=3, linewidth=0.5)
            if len(gps_df) > 0:
                ax.plot(gps_df["lon_deg"].iloc[0], gps_df["lat_deg"].iloc[0], "go", markersize=6)
                ax.plot(gps_df["lon_deg"].iloc[-1], gps_df["lat_deg"].iloc[-1], "rs", markersize=6)
        ax.set_title("GPS Track", fontsize=9)
        ax.set_xlabel("lon", fontsize=8)
        ax.set_ylabel("lat", fontsize=8)
        ax.grid(True, alpha=0.3)

        # [2,0] Altitude
        ax = axes[2, 0]
        if not gps_df.empty and "alt_m" in gps_df.columns:
            alt_v = gps_df["alt_m"].dropna()
            if len(alt_v) > 0:
                ax.fill_between(t_gps[gps_df["alt_m"].notna()],
                                alt_v.values, alpha=0.3, color="green")
                ax.plot(t_gps[gps_df["alt_m"].notna()], alt_v.values, "g-", linewidth=1)
        ax.set_title("Altitude (m)", fontsize=9)
        ax.set_xlabel("t (s)", fontsize=8)
        ax.grid(True, alpha=0.3)

        # [2,1] Metrics text panel
        ax = axes[2, 1]
        ax.axis("off")
        text_lines = [
            f"Samples:   {metrics.get('sample_count', 0):,}",
            f"Frequency: {metrics.get('actual_frequency_hz', 0):.2f} Hz",
            f"Loss:      {metrics.get('packet_loss_estimate', 0):.1f}%",
            f"HR mean:   {metrics.get('hr_mean') or '-'} bpm",
            f"Dist GPS:  {metrics.get('gps_distance_m', 0):.0f} m",
            f"Alt gain:  +{metrics.get('altitude_gain_m', 0):.0f} m",
            f"Quality:   {metrics.get('data_quality_score', 0):.0f}/100",
        ]
        ax.text(
            0.05, 0.9, "\n".join(text_lines),
            transform=ax.transAxes, fontsize=9,
            verticalalignment="top", fontfamily="monospace",
            bbox=dict(boxstyle="round,pad=0.5", facecolor="lightyellow", alpha=0.8)
        )
        ax.set_title("Key Metrics", fontsize=9)

        fig.tight_layout(rect=[0, 0, 1, 0.97])
        path = output_dir / "sensor_overview.png"
        fig.savefig(path, dpi=DPI, bbox_inches="tight")
        plt.close(fig)
        return path

    except Exception as exc:
        logger.warning(f"Overview plot failed: {exc}")
        return None


def _get_relative_time_s(df: pd.DataFrame) -> np.ndarray:
    """Convert absolute timestamps to relative seconds from start."""
    if df.empty or "timestamp_ms" not in df.columns:
        return np.array([], dtype=float)
    ts = df["timestamp_ms"].values.astype(float)
    if len(ts) == 0:
        return ts
    return (ts - ts[0]) / 1000.0


def _equal_aspect_geo(ax: Any, gps_df: pd.DataFrame) -> None:
    """Set equal visual aspect ratio for GPS lat/lon scatter plot."""
    try:
        import math
        lat_center = gps_df["lat_deg"].mean()
        lon_factor = math.cos(math.radians(lat_center))
        ax.set_aspect(1.0 / lon_factor if lon_factor > 0 else 1.0)
    except Exception:
        pass
