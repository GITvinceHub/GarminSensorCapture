"""
Parse JSONL Garmin packets into Python dicts with validation.

Each line of the JSONL file should be a JSON object conforming to
protocol v1 (see 04_docs/02_protocol_communication.md).

Required fields: pv, sid, pi, dtr, s
Optional fields: gps, meta, ef
"""

import json
import logging
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

# Fields that must be present in every valid packet
REQUIRED_FIELDS = frozenset({"pv", "sid", "pi", "dtr", "s"})

# Valid protocol versions this parser understands
SUPPORTED_PROTOCOL_VERSIONS = {1}

# Maximum reasonable packet index (sanity check)
MAX_PACKET_INDEX = 10_000_000

# Maximum reasonable device time reference (year ~2100 in ms)
MAX_DEVICE_TIME_MS = 4_102_444_800_000

# Maximum samples allowed per packet
MAX_SAMPLES_PER_PACKET = 100


def parse_jsonl(filepath: str) -> list[dict[str, Any]]:
    """
    Read and validate a JSONL file, returning a list of valid packet dicts.

    Lines that fail JSON parsing or field validation are skipped with a warning.
    Stats are logged at INFO level after parsing completes.

    Args:
        filepath: Path to the .jsonl file

    Returns:
        List of valid packet dictionaries

    Raises:
        FileNotFoundError: If the file does not exist
        PermissionError: If the file cannot be read
    """
    path = Path(filepath)
    if not path.exists():
        raise FileNotFoundError(f"JSONL file not found: {filepath}")

    valid_packets: list[dict[str, Any]] = []
    total_lines = 0
    empty_lines = 0
    parse_errors = 0
    validation_errors = 0

    logger.info(f"Parsing JSONL file: {path.name} ({path.stat().st_size / 1024:.1f} KB)")

    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line_num, raw_line in enumerate(fh, start=1):
                total_lines += 1

                # Skip blank lines
                stripped = raw_line.strip()
                if not stripped:
                    empty_lines += 1
                    continue

                # Parse JSON
                packet = _parse_line(stripped, line_num)
                if packet is None:
                    parse_errors += 1
                    continue

                # Validate fields
                if not _validate_packet(packet, line_num):
                    validation_errors += 1
                    continue

                valid_packets.append(packet)

    except (PermissionError, OSError) as exc:
        logger.error(f"Cannot read file {filepath}: {exc}")
        raise

    # Log stats
    total_non_empty = total_lines - empty_lines
    logger.info(
        f"Parse complete: {total_lines} lines, {empty_lines} empty, "
        f"{parse_errors} JSON errors, {validation_errors} validation errors, "
        f"{len(valid_packets)}/{total_non_empty} valid packets"
    )

    if total_non_empty > 0:
        success_rate = len(valid_packets) / total_non_empty * 100
        if success_rate < 95:
            logger.warning(
                f"Low parse success rate: {success_rate:.1f}% "
                f"({len(valid_packets)}/{total_non_empty})"
            )

    return valid_packets


def _parse_line(line: str, line_num: int) -> Optional[dict[str, Any]]:
    """
    Parse a single JSON line with error handling.

    Args:
        line:     The stripped JSON string (must not be empty)
        line_num: 1-based line number for error reporting

    Returns:
        Parsed dict, or None on parse error
    """
    try:
        obj = json.loads(line)
        if not isinstance(obj, dict):
            logger.warning(
                f"Line {line_num}: Expected JSON object, got {type(obj).__name__}"
            )
            return None
        return obj
    except json.JSONDecodeError as exc:
        logger.warning(
            f"Line {line_num}: JSON parse error at pos {exc.pos}: {exc.msg} "
            f"(preview: {line[:80]})"
        )
        return None


def _validate_packet(packet: dict[str, Any], line_num: int) -> bool:
    """
    Validate that a packet has all required fields with sensible types and ranges.

    Args:
        packet:   Parsed packet dict
        line_num: 1-based line number for error reporting

    Returns:
        True if valid, False if the packet should be discarded
    """
    # ── Required fields presence ──────────────────────────────────────
    missing = REQUIRED_FIELDS - set(packet.keys())
    if missing:
        logger.warning(
            f"Line {line_num}: Missing required fields: {sorted(missing)}"
        )
        return False

    # ── Protocol version ──────────────────────────────────────────────
    pv = packet.get("pv")
    if not isinstance(pv, int):
        logger.warning(f"Line {line_num}: 'pv' must be int, got {type(pv).__name__}")
        return False
    if pv not in SUPPORTED_PROTOCOL_VERSIONS:
        logger.warning(
            f"Line {line_num}: Unsupported protocol version {pv}. "
            f"Supported: {SUPPORTED_PROTOCOL_VERSIONS}. Attempting best-effort parse."
        )
        # Don't reject — try to parse anyway

    # ── Session ID ────────────────────────────────────────────────────
    sid = packet.get("sid")
    if not isinstance(sid, str) or not sid.strip():
        logger.warning(f"Line {line_num}: 'sid' must be non-empty string")
        return False

    # ── Packet index ──────────────────────────────────────────────────
    pi = packet.get("pi")
    if not isinstance(pi, (int, float)):
        logger.warning(f"Line {line_num}: 'pi' must be numeric, got {type(pi).__name__}")
        return False
    pi_int = int(pi)
    if pi_int < 0:
        logger.warning(f"Line {line_num}: 'pi' is negative: {pi_int}")
        return False
    if pi_int > MAX_PACKET_INDEX:
        logger.warning(f"Line {line_num}: 'pi' too large: {pi_int}")
        return False

    # ── Device time reference ─────────────────────────────────────────
    dtr = packet.get("dtr")
    if not isinstance(dtr, (int, float)):
        logger.warning(f"Line {line_num}: 'dtr' must be numeric")
        return False
    if float(dtr) < 0 or float(dtr) > MAX_DEVICE_TIME_MS:
        logger.warning(f"Line {line_num}: 'dtr' out of range: {dtr}")
        return False

    # ── Samples array ─────────────────────────────────────────────────
    samples = packet.get("s")
    if not isinstance(samples, list):
        logger.warning(f"Line {line_num}: 's' must be a list")
        return False
    if len(samples) == 0:
        logger.debug(f"Line {line_num}: 's' is empty (partial packet)")
        # Allow empty — partial packets are valid (ef=PARTIAL_PACKET)
    if len(samples) > MAX_SAMPLES_PER_PACKET:
        logger.warning(
            f"Line {line_num}: 's' has {len(samples)} samples (max {MAX_SAMPLES_PER_PACKET})"
        )
        return False

    # ── Validate each sample ──────────────────────────────────────────
    for i, sample in enumerate(samples):
        if not isinstance(sample, dict):
            logger.warning(f"Line {line_num}: sample[{i}] is not a dict")
            return False
        # Required sample fields
        for field in ("t", "ax", "ay", "az", "gx", "gy", "gz"):
            if field not in sample:
                logger.warning(f"Line {line_num}: sample[{i}] missing field '{field}'")
                return False

    # ── GPS (optional) validation ─────────────────────────────────────
    gps = packet.get("gps")
    if gps is not None:
        if not isinstance(gps, dict):
            logger.warning(f"Line {line_num}: 'gps' must be a dict")
            # Not a hard failure — just discard GPS
            packet["gps"] = None
        else:
            for req in ("lat", "lon", "ts"):
                if req not in gps:
                    logger.debug(f"Line {line_num}: GPS missing '{req}', clearing GPS")
                    packet["gps"] = None
                    break
            else:
                lat = float(gps.get("lat", 0))
                lon = float(gps.get("lon", 0))
                if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
                    logger.warning(
                        f"Line {line_num}: GPS coordinates out of range: "
                        f"lat={lat}, lon={lon}"
                    )
                    packet["gps"] = None

    return True


def get_session_ids(packets: list[dict[str, Any]]) -> list[str]:
    """
    Extract unique session IDs from a list of packets, preserving first-seen order.

    Args:
        packets: List of validated packet dicts

    Returns:
        Ordered list of unique session IDs
    """
    seen: set[str] = set()
    result: list[str] = []
    for p in packets:
        sid = p.get("sid", "")
        if sid and sid not in seen:
            seen.add(sid)
            result.append(sid)
    return result


def filter_by_session(
    packets: list[dict[str, Any]], session_id: str
) -> list[dict[str, Any]]:
    """
    Filter packets to only those belonging to a specific session.

    Args:
        packets:    List of packet dicts
        session_id: Target session ID

    Returns:
        Filtered list
    """
    return [p for p in packets if p.get("sid") == session_id]
