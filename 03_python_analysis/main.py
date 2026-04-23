#!/usr/bin/env python3
"""
Garmin Sensor Capture - Python Analysis Pipeline

Analyzes a JSONL file produced by the Android companion app and generates:
  - imu_data.csv       : IMU sensor data table
  - gps_data.csv       : GPS data table
  - metrics.json       : Session quality metrics
  - summary.txt        : Human-readable report
  - *.png              : Sensor visualization plots

Usage:
    python main.py <session.jsonl> [--output-dir ./output]

Example:
    python main.py sample_data/sample_session.jsonl --output-dir ./output/test
"""

import argparse
import sys
import logging
from pathlib import Path

# Configure logging before importing modules
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("main")

from modules.parser import parse_jsonl
from modules.normalizer import normalize_data
from modules.metrics import compute_metrics
from modules.plotter import generate_plots
from modules.reporter import generate_report


def main() -> int:
    """
    Main entry point for the analysis pipeline.

    Returns:
        Exit code (0 = success, 1 = error)
    """
    # ── Argument parsing ──────────────────────────────────────────────
    parser = argparse.ArgumentParser(
        description="Analyze Garmin sensor capture JSONL file",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )
    parser.add_argument(
        "input",
        help="Path to the JSONL session file"
    )
    parser.add_argument(
        "--output-dir",
        default="./output",
        help="Output directory for results (default: ./output)"
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Enable verbose (DEBUG) logging"
    )
    parser.add_argument(
        "--no-plots",
        action="store_true",
        help="Skip plot generation (faster)"
    )

    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # ── Input validation ──────────────────────────────────────────────
    input_path = Path(args.input)
    if not input_path.exists():
        logger.error(f"Input file not found: {input_path}")
        return 1
    if not input_path.suffix == ".jsonl" and not input_path.suffix == ".json":
        logger.warning(f"Expected .jsonl file, got: {input_path.suffix}")

    # ── Output directory ──────────────────────────────────────────────
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    logger.info(f"Output directory: {output_dir.resolve()}")

    # ── Pipeline ──────────────────────────────────────────────────────
    try:
        # Step 1: Parse
        print(f"[1/5] Parsing {input_path.name}...")
        packets = parse_jsonl(str(input_path))
        if not packets:
            logger.error("No valid packets found in input file")
            return 1
        print(f"      → {len(packets)} valid packets")

        # Step 2: Normalize
        print(f"[2/5] Normalizing {len(packets)} packets...")
        imu_df, gps_df = normalize_data(packets)
        print(f"      → {len(imu_df)} IMU samples, {len(gps_df)} GPS fixes")

        # Step 3: Metrics
        print(f"[3/5] Computing metrics...")
        metrics = compute_metrics(imu_df, gps_df)
        print(f"      → Duration: {metrics.get('duration_s', 0):.1f}s, "
              f"Frequency: {metrics.get('actual_frequency_hz', 0):.2f} Hz, "
              f"Loss: {metrics.get('packet_loss_estimate', 0):.1f}%")

        # Step 4: Plots
        if not args.no_plots:
            print(f"[4/5] Generating plots...")
            generate_plots(imu_df, gps_df, metrics, output_dir)
            print(f"      → Plots written to {output_dir}/")
        else:
            print(f"[4/5] Plots skipped (--no-plots)")

        # Step 5: Report
        print(f"[5/5] Writing report...")
        generate_report(packets, imu_df, gps_df, metrics, output_dir)
        print(f"      → Report written to {output_dir}/")

        print(f"\nDone. Results in {output_dir.resolve()}/")
        return 0

    except KeyboardInterrupt:
        print("\nInterrupted by user")
        return 1
    except Exception as exc:
        logger.exception(f"Pipeline failed: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
