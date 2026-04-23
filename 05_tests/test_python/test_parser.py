"""
Unit tests for modules/parser.py

Tests cover: valid packets, missing fields, invalid JSON,
empty files, multiple packets, edge cases.
"""

import json
import os
import sys
import pytest

# Add the analysis module to sys.path so imports work from the test directory
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../03_python_analysis"))

from modules.parser import (
    parse_jsonl,
    _validate_packet,
    _parse_line,
    get_session_ids,
    filter_by_session,
    REQUIRED_FIELDS,
)


# ── Helpers ───────────────────────────────────────────────────────────

def _make_valid_packet(pi: int = 0) -> dict:
    """Return a minimal valid packet dict."""
    return {
        "received_at": "2024-04-22T14:30:22.000Z",
        "pv":  1,
        "sid": "20240422_143022",
        "pi":  pi,
        "dtr": 1713794022000 + pi * 1000,
        "s": [
            {
                "t": 0, "ax": 15.0, "ay": -983.0, "az": 124.0,
                "gx": 0.5, "gy": -0.3, "gz": 0.1, "hr": 72
            }
        ],
        "gps": {"lat": 48.8566, "lon": 2.3522, "ts": 1713794022 + pi},
        "meta": {"bat": 85, "temp": 22.5},
        "ef": 0,
    }


def _write_jsonl(tmp_path, packets: list) -> str:
    """Write packets to a temp JSONL file and return path."""
    path = tmp_path / "test.jsonl"
    with open(path, "w") as f:
        for p in packets:
            f.write(json.dumps(p) + "\n")
    return str(path)


# ── test_parse_valid_packet ───────────────────────────────────────────

class TestParseValidPacket:
    """Tests for successful parsing of well-formed packets."""

    def test_single_valid_packet(self, tmp_path):
        """parse_jsonl should return one packet from a single-line JSONL."""
        pkt = _make_valid_packet()
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert len(result) == 1

    def test_packet_contains_required_fields(self, tmp_path):
        """Each returned packet should have all required fields."""
        pkt = _make_valid_packet()
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        for field in REQUIRED_FIELDS:
            assert field in result[0], f"Missing field: {field}"

    def test_packet_values_preserved(self, tmp_path):
        """Parsed packet should have the same values as the input."""
        pkt = _make_valid_packet()
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert result[0]["sid"] == pkt["sid"]
        assert result[0]["pi"]  == pkt["pi"]
        assert result[0]["dtr"] == pkt["dtr"]

    def test_samples_preserved(self, tmp_path):
        """Sample list should be preserved with correct length."""
        pkt = _make_valid_packet()
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert len(result[0]["s"]) == 1
        assert result[0]["s"][0]["ax"] == 15.0

    def test_gps_preserved(self, tmp_path):
        """GPS data should be preserved if valid."""
        pkt = _make_valid_packet()
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert result[0]["gps"] is not None
        assert result[0]["gps"]["lat"] == 48.8566

    def test_optional_fields_present(self, tmp_path):
        """Optional fields (meta, ef) should be present when provided."""
        pkt = _make_valid_packet()
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert result[0]["meta"]["bat"] == 85
        assert result[0]["ef"] == 0


# ── test_parse_missing_required_field ────────────────────────────────

class TestParseMissingRequiredField:
    """Tests for packets missing required fields."""

    @pytest.mark.parametrize("missing_field", ["pv", "sid", "pi", "dtr", "s"])
    def test_missing_required_field_skipped(self, tmp_path, missing_field):
        """Packets missing any required field should be skipped."""
        pkt = _make_valid_packet()
        del pkt[missing_field]
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert len(result) == 0, f"Expected 0 results when '{missing_field}' is missing"

    def test_mixed_valid_invalid(self, tmp_path):
        """Only valid packets should be returned when mixed with invalid ones."""
        valid_pkt   = _make_valid_packet(pi=0)
        invalid_pkt = _make_valid_packet(pi=1)
        del invalid_pkt["sid"]

        path = _write_jsonl(tmp_path, [valid_pkt, invalid_pkt])
        result = parse_jsonl(path)
        assert len(result) == 1
        assert result[0]["pi"] == 0

    def test_empty_sid_rejected(self, tmp_path):
        """Packet with empty session ID should be rejected."""
        pkt = _make_valid_packet()
        pkt["sid"] = ""
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert len(result) == 0

    def test_negative_pi_rejected(self, tmp_path):
        """Packet with negative packet index should be rejected."""
        pkt = _make_valid_packet()
        pkt["pi"] = -1
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert len(result) == 0

    def test_non_list_samples_rejected(self, tmp_path):
        """Packet with 's' as non-list should be rejected."""
        pkt = _make_valid_packet()
        pkt["s"] = "not a list"
        path = _write_jsonl(tmp_path, [pkt])
        result = parse_jsonl(path)
        assert len(result) == 0


# ── test_parse_invalid_json ───────────────────────────────────────────

class TestParseInvalidJson:
    """Tests for handling malformed JSON lines."""

    def test_completely_invalid_json(self, tmp_path):
        """Lines that are not JSON at all should be skipped."""
        path = tmp_path / "bad.jsonl"
        with open(path, "w") as f:
            f.write("this is not json\n")
            f.write(json.dumps(_make_valid_packet()) + "\n")
        result = parse_jsonl(str(path))
        assert len(result) == 1  # Only the valid one

    def test_truncated_json(self, tmp_path):
        """Truncated JSON should be skipped."""
        path = tmp_path / "truncated.jsonl"
        with open(path, "w") as f:
            f.write('{"pv": 1, "sid": "test"\n')  # Truncated
            f.write(json.dumps(_make_valid_packet()) + "\n")
        result = parse_jsonl(str(path))
        assert len(result) == 1

    def test_json_array_rejected(self, tmp_path):
        """JSON arrays (not objects) should be rejected."""
        path = tmp_path / "array.jsonl"
        with open(path, "w") as f:
            f.write('[1, 2, 3]\n')
            f.write(json.dumps(_make_valid_packet()) + "\n")
        result = parse_jsonl(str(path))
        assert len(result) == 1

    def test_json_string_rejected(self, tmp_path):
        """JSON string primitives should be rejected."""
        path = tmp_path / "string.jsonl"
        with open(path, "w") as f:
            f.write('"just a string"\n')
            f.write(json.dumps(_make_valid_packet()) + "\n")
        result = parse_jsonl(str(path))
        assert len(result) == 1


# ── test_parse_empty_file ─────────────────────────────────────────────

class TestParseEmptyFile:
    """Tests for empty or whitespace-only files."""

    def test_empty_file(self, tmp_path):
        """Empty file should return empty list without error."""
        path = tmp_path / "empty.jsonl"
        path.touch()
        result = parse_jsonl(str(path))
        assert result == []

    def test_whitespace_only_file(self, tmp_path):
        """File with only blank lines should return empty list."""
        path = tmp_path / "blank.jsonl"
        with open(path, "w") as f:
            f.write("\n\n\n   \n\t\n")
        result = parse_jsonl(str(path))
        assert result == []

    def test_file_not_found(self):
        """FileNotFoundError should be raised for non-existent file."""
        with pytest.raises(FileNotFoundError):
            parse_jsonl("/nonexistent/path/file.jsonl")


# ── test_parse_multiple_packets ───────────────────────────────────────

class TestParseMultiplePackets:
    """Tests for parsing files with multiple packets."""

    def test_ten_packets_parsed(self, tmp_path):
        """All 10 valid packets should be returned."""
        packets = [_make_valid_packet(pi=i) for i in range(10)]
        path = _write_jsonl(tmp_path, packets)
        result = parse_jsonl(path)
        assert len(result) == 10

    def test_packet_order_preserved(self, tmp_path):
        """Packets should be returned in file order."""
        packets = [_make_valid_packet(pi=i) for i in range(5)]
        path = _write_jsonl(tmp_path, packets)
        result = parse_jsonl(path)
        for expected_pi, pkt in enumerate(result):
            assert pkt["pi"] == expected_pi

    def test_multiple_sessions(self, tmp_path):
        """Packets from multiple sessions should all be returned."""
        packets = []
        for pi in range(3):
            p = _make_valid_packet(pi=pi)
            p["sid"] = "session_A"
            packets.append(p)
        for pi in range(3):
            p = _make_valid_packet(pi=pi)
            p["sid"] = "session_B"
            packets.append(p)

        path = _write_jsonl(tmp_path, packets)
        result = parse_jsonl(path)
        assert len(result) == 6

    def test_get_session_ids(self, tmp_path):
        """get_session_ids should return unique IDs in order."""
        packets = []
        for sid in ("session_A", "session_B", "session_A"):
            p = _make_valid_packet()
            p["sid"] = sid
            packets.append(p)

        path = _write_jsonl(tmp_path, packets)
        result = parse_jsonl(path)
        sids = get_session_ids(result)
        assert sids == ["session_A", "session_B"]

    def test_filter_by_session(self, tmp_path):
        """filter_by_session should return only matching packets."""
        packets = []
        for pi in range(5):
            p = _make_valid_packet(pi=pi)
            p["sid"] = "session_A" if pi < 3 else "session_B"
            packets.append(p)

        path = _write_jsonl(tmp_path, packets)
        result = parse_jsonl(path)
        filtered = filter_by_session(result, "session_A")
        assert len(filtered) == 3
        assert all(p["sid"] == "session_A" for p in filtered)


# ── test__validate_packet (unit) ──────────────────────────────────────

class TestValidatePacket:
    """Unit tests for the _validate_packet helper."""

    def test_valid_packet_returns_true(self):
        """_validate_packet should return True for a valid packet."""
        pkt = _make_valid_packet()
        assert _validate_packet(pkt, 1) is True

    def test_invalid_gps_cleared(self):
        """GPS with out-of-range lat should be set to None, packet still valid."""
        pkt = _make_valid_packet()
        pkt["gps"]["lat"] = 200.0  # Invalid
        result = _validate_packet(pkt, 1)
        assert result is True  # Packet is valid
        assert pkt["gps"] is None  # GPS was cleared

    def test_empty_samples_allowed(self):
        """Packet with empty samples list should be valid (partial packet)."""
        pkt = _make_valid_packet()
        pkt["s"] = []
        assert _validate_packet(pkt, 1) is True


# ── test__parse_line (unit) ───────────────────────────────────────────

class TestParseLine:
    """Unit tests for the _parse_line helper."""

    def test_valid_json_dict(self):
        """Valid JSON object should be parsed to dict."""
        result = _parse_line('{"key": "value"}', 1)
        assert result == {"key": "value"}

    def test_invalid_json_returns_none(self):
        """Invalid JSON should return None."""
        result = _parse_line("not json", 1)
        assert result is None

    def test_json_array_returns_none(self):
        """JSON array should return None (not a dict)."""
        result = _parse_line("[1, 2, 3]", 1)
        assert result is None

    def test_json_null_returns_none(self):
        """JSON null becomes Python None — not a dict, so returns None."""
        result = _parse_line("null", 1)
        assert result is None
