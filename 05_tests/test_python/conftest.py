"""
pytest fixtures shared across all Python test modules.

Provides ready-to-use sample data for parser, normalizer,
metrics, and reporter tests.
"""

import pytest
import pandas as pd
import numpy as np
from typing import Any


# ── Raw packet fixtures ───────────────────────────────────────────────

@pytest.fixture
def sample_sample() -> dict[str, Any]:
    """A single valid IMU sample dict."""
    return {
        "t":  0,
        "ax": 15.0,
        "ay": -983.0,
        "az": 124.0,
        "gx": 0.5,
        "gy": -0.3,
        "gz": 0.1,
        "mx": 22.5,
        "my": -15.3,
        "mz": 44.1,
        "hr": 72,
    }


@pytest.fixture
def sample_gps() -> dict[str, Any]:
    """A valid GPS data dict."""
    return {
        "lat": 48.8566,
        "lon": 2.3522,
        "alt": 35.0,
        "spd": 1.2,
        "hdg": 270.0,
        "acc": 5.0,
        "ts":  1713794022,
    }


@pytest.fixture
def sample_meta() -> dict[str, Any]:
    """A valid meta data dict."""
    return {"bat": 85, "temp": 22.5}


@pytest.fixture
def sample_packet(sample_sample, sample_gps, sample_meta) -> dict[str, Any]:
    """A single valid packet dict (5 samples)."""
    samples = []
    for i in range(5):
        s = dict(sample_sample)
        s["t"]  = i * 40
        s["hr"] = 72 + i
        samples.append(s)

    return {
        "received_at": "2024-04-22T14:30:22.000Z",
        "session_id":  "20240422_143022",
        "pv":          1,
        "sid":         "20240422_143022",
        "pi":          0,
        "dtr":         1713794022000,
        "s":           samples,
        "gps":         sample_gps,
        "meta":        sample_meta,
        "ef":          0,
    }


@pytest.fixture
def sample_packets_list(sample_packet) -> list[dict[str, Any]]:
    """A list of 5 valid packets with sequential indices."""
    packets = []
    for pi in range(5):
        pkt = dict(sample_packet)
        pkt["pi"]  = pi
        pkt["dtr"] = 1713794022000 + pi * 1000

        # Shift GPS
        gps = dict(pkt["gps"])
        gps["lat"] = 48.8566 + pi * 0.0001
        gps["ts"]  = 1713794022 + pi
        pkt["gps"] = gps

        # Offset samples
        samples = []
        for i, s in enumerate(pkt["s"]):
            ns = dict(s)
            ns["t"] = i * 40
            samples.append(ns)
        pkt["s"] = samples

        packets.append(pkt)
    return packets


# ── DataFrame fixtures ────────────────────────────────────────────────

@pytest.fixture
def sample_imu_df() -> pd.DataFrame:
    """A minimal IMU DataFrame with 50 samples at 25 Hz."""
    n = 50
    base_ts = 1713794022000

    data = {
        "timestamp_ms": [base_ts + i * 40 for i in range(n)],
        "session_id":   ["20240422_143022"] * n,
        "packet_index": [i // 25 for i in range(n)],
        "sample_index": [i % 25 for i in range(n)],
        "ax_g":         np.random.normal(0.0, 0.05, n).tolist(),
        "ay_g":         np.random.normal(0.0, 0.05, n).tolist(),
        "az_g":         (np.random.normal(-0.983, 0.01, n)).tolist(),
        "gx_dps":       np.random.normal(0.0, 0.5, n).tolist(),
        "gy_dps":       np.random.normal(0.0, 0.5, n).tolist(),
        "gz_dps":       np.random.normal(0.0, 0.2, n).tolist(),
        "mx_uT":        [22.5] * n,
        "my_uT":        [-15.3] * n,
        "mz_uT":        [44.1] * n,
        "hr_bpm":       [72.0 + i * 0.5 for i in range(n)],
        "received_at":  ["2024-04-22T14:30:22.000Z"] * n,
        "is_duplicate": [False] * n,
        "interpolated": [False] * n,
    }
    df = pd.DataFrame(data)
    df["timestamp_ms"] = df["timestamp_ms"].astype("int64")
    return df


@pytest.fixture
def sample_gps_df() -> pd.DataFrame:
    """A minimal GPS DataFrame with 5 fixes (1 Hz)."""
    n = 5
    base_ts = 1713794022000

    data = {
        "timestamp_ms": [base_ts + i * 1000 for i in range(n)],
        "session_id":   ["20240422_143022"] * n,
        "packet_index": list(range(n)),
        "lat_deg":      [48.8566 + i * 0.0001 for i in range(n)],
        "lon_deg":      [2.3522  + i * 0.0001 for i in range(n)],
        "alt_m":        [35.0 + i * 0.5 for i in range(n)],
        "speed_ms":     [1.2 + i * 0.1 for i in range(n)],
        "heading_deg":  [270.0] * n,
        "accuracy_m":   [5.0] * n,
        "received_at":  ["2024-04-22T14:30:22.000Z"] * n,
        "is_duplicate": [False] * n,
    }
    df = pd.DataFrame(data)
    df["timestamp_ms"] = df["timestamp_ms"].astype("int64")
    return df


@pytest.fixture
def empty_imu_df() -> pd.DataFrame:
    """An empty IMU DataFrame with correct column schema."""
    return pd.DataFrame(columns=[
        "timestamp_ms", "session_id", "packet_index", "sample_index",
        "ax_g", "ay_g", "az_g",
        "gx_dps", "gy_dps", "gz_dps",
        "mx_uT", "my_uT", "mz_uT",
        "hr_bpm", "received_at", "is_duplicate", "interpolated"
    ])


@pytest.fixture
def empty_gps_df() -> pd.DataFrame:
    """An empty GPS DataFrame with correct column schema."""
    return pd.DataFrame(columns=[
        "timestamp_ms", "session_id", "packet_index",
        "lat_deg", "lon_deg", "alt_m", "speed_ms",
        "heading_deg", "accuracy_m", "received_at", "is_duplicate"
    ])


# ── JSONL file fixtures ───────────────────────────────────────────────

@pytest.fixture
def sample_jsonl_file(tmp_path, sample_packets_list) -> str:
    """Write sample packets to a temporary JSONL file and return path."""
    import json
    path = tmp_path / "test_session.jsonl"
    with open(path, "w", encoding="utf-8") as f:
        for pkt in sample_packets_list:
            f.write(json.dumps(pkt) + "\n")
    return str(path)


@pytest.fixture
def invalid_jsonl_file(tmp_path) -> str:
    """A JSONL file with a mix of valid and invalid lines."""
    import json
    path = tmp_path / "invalid_session.jsonl"
    lines = [
        "",  # blank line
        "not json at all",  # invalid JSON
        json.dumps({"pv": 1, "sid": "test", "pi": 0, "dtr": 1713794022000,
                    "s": [{"t": 0, "ax": 10.0, "ay": -980.0, "az": 120.0,
                           "gx": 0.5, "gy": -0.3, "gz": 0.1}]}),  # valid
        json.dumps({"pv": 1}),  # missing required fields
        json.dumps({"pv": 1, "sid": "", "pi": 0, "dtr": 1713794022000, "s": []}),  # blank sid
    ]
    with open(path, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(line + "\n")
    return str(path)
