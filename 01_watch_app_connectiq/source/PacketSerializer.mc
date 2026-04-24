//! PacketSerializer.mc
//! Builds protocol v1 data packets (§8.1). Returns a String (JSON) or null on failure.
//!
//! C-020: size <= MAX_PACKET_SIZE (4096). Truncates samples + sets EF_PARTIAL_PACKET if needed.
//! INV-005: data packet has no "pt" key; "s" array is non-empty (unless PARTIAL).
using Toybox.Lang;
using Toybox.System;

module PacketSerializer {

    const MAX_PACKET_SIZE = 4096;
    const PROTOCOL_VERSION = 1;

    const EF_SENSOR_ERROR     = 0x01;
    const EF_GPS_ERROR        = 0x02;
    const EF_BUFFER_OVERFLOW  = 0x04;
    const EF_PARTIAL_PACKET   = 0x08;

    //! Serialize a data packet.
    //! Args:
    //!   sid: String      — session id
    //!   pi: Number       — packet index
    //!   dtr: Number      — device time reference (System.getTimer())
    //!   samples: Array   — sample dictionaries
    //!   rrIntervals: Array<Number> or null
    //!   gps: Dictionary or null
    //!   metaDict: Dictionary — must contain "bat"
    //!   ef: Number       — starting error flags
    //! Returns: String (JSON, <= MAX_PACKET_SIZE) or null on failure.
    function serializePacket(sid, pi, dtr, samples, rrIntervals, gps, metaDict, ef) {
        try {
            if (sid == null || sid.equals("")) { return null; }
            if (pi < 0) { return null; }
            if (samples == null) { samples = []; }
            if (metaDict == null) { metaDict = { "bat" => 0 }; }

            var dict = {
                "pv"  => PROTOCOL_VERSION,
                "sid" => sid,
                "pi"  => pi,
                "dtr" => dtr,
                "s"   => samples,
                "meta" => metaDict,
                "ef"  => ef
            };
            if (rrIntervals != null && rrIntervals.size() > 0) {
                dict.put("rr", rrIntervals);
            }
            if (gps != null) {
                dict.put("gps", gps);
            }

            var json = _encodeValue(dict);

            // Size guard: truncate samples progressively if over limit.
            if (json.length() > MAX_PACKET_SIZE) {
                var truncated = samples;
                while (truncated.size() > 1 && json.length() > MAX_PACKET_SIZE) {
                    // Drop the last sample at a time — callers can re-enqueue if needed.
                    truncated = truncated.slice(0, truncated.size() - 1);
                    dict.put("s", truncated);
                    dict.put("ef", ef | EF_PARTIAL_PACKET);
                    json = _encodeValue(dict);
                }
                if (json.length() > MAX_PACKET_SIZE) {
                    // Give up — emit empty s + PARTIAL flag.
                    dict.put("s", []);
                    dict.put("ef", ef | EF_PARTIAL_PACKET);
                    json = _encodeValue(dict);
                    if (json.length() > MAX_PACKET_SIZE) {
                        return null;
                    }
                }
            }
            return json;
        } catch (ex instanceof Lang.Exception) {
            System.println("PacketSerializer: FATAL " + ex.getErrorMessage());
            return null;
        }
    }

    //! Recursive JSON encoder. Monkey C has no built-in json.stringify.
    function _encodeValue(v) {
        if (v == null) {
            return "null";
        }
        if (v instanceof Lang.Boolean) {
            return v ? "true" : "false";
        }
        if (v instanceof Lang.Number || v instanceof Lang.Long) {
            return v.toString();
        }
        if (v instanceof Lang.Float || v instanceof Lang.Double) {
            var f = v.toFloat();
            // Guard against NaN / ±Inf (serialize as 0).
            if (f != f) { return "0"; }
            return f.format("%.3f");
        }
        if (v instanceof Lang.String) {
            return "\"" + _escapeString(v) + "\"";
        }
        if (v instanceof Lang.Array) {
            var out = "[";
            var n = v.size();
            for (var i = 0; i < n; i += 1) {
                if (i > 0) { out += ","; }
                out += _encodeValue(v[i]);
            }
            return out + "]";
        }
        if (v instanceof Lang.Dictionary) {
            var out2 = "{";
            var keys = v.keys();
            var m = keys.size();
            for (var j = 0; j < m; j += 1) {
                if (j > 0) { out2 += ","; }
                var k = keys[j];
                out2 += "\"" + _escapeString(k.toString()) + "\":" + _encodeValue(v[k]);
            }
            return out2 + "}";
        }
        // Fallback: stringify.
        return "\"" + _escapeString(v.toString()) + "\"";
    }

    function _escapeString(s) {
        // Minimal: escape backslash, double-quote, newline, tab.
        var out = "";
        var n = s.length();
        for (var i = 0; i < n; i += 1) {
            var c = s.substring(i, i + 1);
            if (c.equals("\\")) {
                out += "\\\\";
            } else if (c.equals("\"")) {
                out += "\\\"";
            } else if (c.equals("\n")) {
                out += "\\n";
            } else if (c.equals("\r")) {
                out += "\\r";
            } else if (c.equals("\t")) {
                out += "\\t";
            } else {
                out += c;
            }
        }
        return out;
    }
}
