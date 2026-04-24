import Toybox.Lang;
import Toybox.System;

//! JSON protocol v1 serializer.
//!
//! Implements contract C-020 per SPECIFICATION.md §7.3 and protocol §8.
//! Produces compact JSON packets bounded by MAX_PACKET_SIZE (4096 chars).
//!
//! Three packet kinds:
//!  - Data packet:   pt absent, s non-empty. INV-005.
//!  - Header packet: pt="header", pi=0, no s array. INV-003.
//!  - Footer packet: pt="footer", no s array.       INV-004.
class PacketSerializer {

    //! Error flag bitmask (§8.6).
    static const EF_SENSOR_ERROR    = 0x01;
    static const EF_GPS_ERROR       = 0x02;
    static const EF_BUFFER_OVERFLOW = 0x04;
    static const EF_PARTIAL_PACKET  = 0x08;
    static const EF_CLOCK_SKEW      = 0x10;
    static const EF_COMM_RETRY      = 0x20;

    static const MAX_PACKET_SIZE  = 4096;
    static const PROTOCOL_VERSION = 1;

    //! C-020 serializePacket — data packet (§8.1).
    //! Precondition: sessionId != ""; packetIndex >= 0; samples.size() > 0;
    //!   metaDict.get("bat") != null.
    //! Postcondition: returns JSON String of length <= MAX_PACKET_SIZE,
    //!   OR null on fatal error. Samples truncated with EF_PARTIAL_PACKET if needed.
    static function serializePacket(
        sessionId    as String,
        packetIndex  as Number,
        deviceTime   as Number,
        samples      as Array<Dictionary>,
        rrIntervals  as Array or Null,
        gpsData      as Dictionary or Null,
        metaDict     as Dictionary,
        errorFlags   as Number
    ) as String or Null {

        if (samples == null || samples.size() == 0) {
            System.println("PacketSerializer: no samples to serialize");
            return null;
        }

        var ef = errorFlags;
        var json = "";

        try {
            var samplesJson = _serializeSamples(samples, MAX_PACKET_SIZE);
            var samplesStr  = samplesJson.get("json") as String;
            var countUsed   = samplesJson.get("count") as Number;

            if (countUsed < samples.size()) {
                ef |= EF_PARTIAL_PACKET;
            }

            var gpsStr = "";
            if (gpsData != null) {
                gpsStr = _serializeGps(gpsData as Dictionary);
            }

            var metaStr = _serializeMeta(metaDict);

            var rrStr = "";
            if (rrIntervals != null && rrIntervals.size() > 0) {
                rrStr = "[";
                for (var i = 0; i < rrIntervals.size(); i++) {
                    if (i > 0) { rrStr += ","; }
                    rrStr += rrIntervals[i].toString();
                }
                rrStr += "]";
            }

            var battery = (metaDict.get("bat") != null) ? metaDict.get("bat") as Number : 0;
            json = "{";
            json += "\"pv\":"  + PROTOCOL_VERSION.toString() + ",";
            json += "\"sid\":\"" + sessionId + "\",";
            json += "\"pi\":"  + packetIndex.toString() + ",";
            json += "\"dtr\":" + deviceTime.toString() + ",";
            json += "\"s\":"   + samplesStr + ",";

            if (rrStr.length() > 0) { json += "\"rr\":"  + rrStr  + ","; }
            if (gpsStr.length() > 0){ json += "\"gps\":" + gpsStr + ","; }

            json += "\"meta\":" + metaStr + ",";
            json += "\"ef\":"   + ef.toString();
            json += "}";

            // INVARIANT: size <= MAX_PACKET_SIZE.
            if (json.length() > MAX_PACKET_SIZE) {
                ef |= EF_PARTIAL_PACKET;
                json = _truncateToMaxSize(sessionId, packetIndex, deviceTime, battery, ef);
            }

        } catch (ex instanceof Lang.Exception) {
            System.println("PacketSerializer: exception: " + ex.getErrorMessage());
            return null;
        }

        return json;
    }

    //! Header packet (§8.2) — pt="header", pi=0.
    //! Contains user profile, device info and pre-session sensor histories.
    //! No `s` array, no `ef`. FR-014: Android must accept meta packets without samples.
    static function serializeHeaderPacket(
        sessionId   as String,
        deviceTime  as Number,
        userProfile as Dictionary,
        deviceInfo  as Dictionary,
        histories   as Dictionary
    ) as String or Null {
        return _serializeMetaPacket("header", 0, sessionId, deviceTime,
            userProfile, deviceInfo, histories);
    }

    //! Footer packet (§8.3) — pt="footer", in-session histories only.
    static function serializeFooterPacket(
        sessionId   as String,
        packetIndex as Number,
        deviceTime  as Number,
        histories   as Dictionary
    ) as String or Null {
        return _serializeMetaPacket("footer", packetIndex, sessionId, deviceTime,
            null, null, histories);
    }

    private static function _serializeMetaPacket(
        packetType  as String,
        packetIndex as Number,
        sessionId   as String,
        deviceTime  as Number,
        userProfile as Dictionary or Null,
        deviceInfo  as Dictionary or Null,
        histories   as Dictionary or Null
    ) as String or Null {
        try {
            var json = "{";
            json += "\"pv\":"   + PROTOCOL_VERSION.toString() + ",";
            json += "\"pt\":\"" + packetType + "\",";
            json += "\"sid\":\""+ sessionId + "\",";
            json += "\"pi\":"   + packetIndex.toString() + ",";
            json += "\"dtr\":"  + deviceTime.toString();

            if (userProfile != null && userProfile.size() > 0) {
                json += ",\"user\":" + _serializeFlatDict(userProfile);
            }
            if (deviceInfo != null && deviceInfo.size() > 0) {
                json += ",\"device\":" + _serializeFlatDict(deviceInfo);
            }

            if (histories != null && histories.size() > 0) {
                json += ",\"history\":{";
                var keys = histories.keys() as Array;
                var first = true;
                for (var i = 0; i < keys.size(); i++) {
                    var k = keys[i] as String;
                    var arr = histories.get(k) as Array;
                    if (arr == null || arr.size() == 0) { continue; }
                    if (!first) { json += ","; }
                    first = false;
                    json += "\"" + k + "\":" + _serializeHistoryArray(arr,
                        MAX_PACKET_SIZE - json.length() - 200);
                }
                json += "}";
            }
            json += "}";

            if (json.length() > MAX_PACKET_SIZE) {
                // Meta overflowed → emit a minimal meta with empty history.
                json = "{\"pv\":" + PROTOCOL_VERSION.toString()
                     + ",\"pt\":\"" + packetType + "\""
                     + ",\"sid\":\"" + sessionId + "\""
                     + ",\"pi\":" + packetIndex.toString()
                     + ",\"dtr\":" + deviceTime.toString()
                     + ",\"history\":{},\"trunc\":true}";
            }
            return json;

        } catch (ex instanceof Lang.Exception) {
            System.println("PacketSerializer: meta packet failed: " + ex.getErrorMessage());
            return null;
        }
    }

    // ── Helpers ───────────────────────────────────────────────────

    private static function _serializeFlatDict(d as Dictionary) as String {
        var out = "{";
        var keys = d.keys() as Array;
        var first = true;
        for (var i = 0; i < keys.size(); i++) {
            var k = keys[i] as String;
            var v = d.get(k);
            if (v == null) { continue; }
            if (!first) { out += ","; }
            first = false;
            out += "\"" + k + "\":";
            if (v instanceof String) {
                out += "\"" + v + "\"";
            } else if (v instanceof Float) {
                out += (v as Float).format("%.3f");
            } else {
                out += v.toString();
            }
        }
        out += "}";
        return out;
    }

    private static function _serializeMeta(m as Dictionary) as String {
        var out = "{";
        var bat = m.get("bat");
        out += "\"bat\":" + (bat != null ? bat.toString() : "0");

        var keys = m.keys() as Array;
        for (var i = 0; i < keys.size(); i++) {
            var k = keys[i] as String;
            if (k.equals("bat")) { continue; }
            var v = m.get(k);
            if (v == null) { continue; }
            out += ",\"" + k + "\":";
            if (v instanceof String) {
                out += "\"" + v + "\"";
            } else if (v instanceof Float) {
                out += (v as Float).format("%.3f");
            } else {
                out += v.toString();
            }
        }
        out += "}";
        return out;
    }

    private static function _serializeHistoryArray(arr as Array, sizeBudget as Number) as String {
        var out  = "[";
        var used = 1;
        var first = true;
        for (var i = 0; i < arr.size(); i++) {
            var entry = arr[i] as Array;
            if (entry == null || entry.size() < 2) { continue; }
            var ts = entry[0];
            var v  = entry[1];
            var pair = "[" + ts.toString() + "," + v.toString() + "]";
            var needed = pair.length() + (first ? 0 : 1);
            if (used + needed + 1 > sizeBudget) { break; }
            if (!first) { out += ","; used += 1; }
            first = false;
            out += pair;
            used += pair.length();
        }
        out += "]";
        return out;
    }

    private static function _serializeSamples(
        samples   as Array<Dictionary>,
        sizeLimit as Number
    ) as Dictionary {
        var remainingBudget = sizeLimit - 250;  // envelope reserve
        var samplesStr = "[";
        var count = 0;

        for (var i = 0; i < samples.size(); i++) {
            var sampleStr = _serializeSample(samples[i] as Dictionary);
            var needed = sampleStr.length() + (i > 0 ? 1 : 0) + 1;
            if (samplesStr.length() + needed > remainingBudget) {
                break;
            }
            if (i > 0) { samplesStr += ","; }
            samplesStr += sampleStr;
            count++;
        }

        samplesStr += "]";
        return { "json" => samplesStr, "count" => count };
    }

    private static function _serializeSample(s as Dictionary) as String {
        var t  = (s.get("t")  != null ? s.get("t")  : 0)    as Number;
        var ax = (s.get("ax") != null ? s.get("ax") : 0.0f) as Float;
        var ay = (s.get("ay") != null ? s.get("ay") : 0.0f) as Float;
        var az = (s.get("az") != null ? s.get("az") : 0.0f) as Float;
        var gx = (s.get("gx") != null ? s.get("gx") : 0.0f) as Float;
        var gy = (s.get("gy") != null ? s.get("gy") : 0.0f) as Float;
        var gz = (s.get("gz") != null ? s.get("gz") : 0.0f) as Float;
        var mx = (s.get("mx") != null ? s.get("mx") : 0.0f) as Float;
        var my = (s.get("my") != null ? s.get("my") : 0.0f) as Float;
        var mz = (s.get("mz") != null ? s.get("mz") : 0.0f) as Float;
        var hr = (s.get("hr") != null ? s.get("hr") : 0)    as Number;

        return "{\"t\":" + t.toString()
            + ",\"ax\":" + ax.format("%.3f")
            + ",\"ay\":" + ay.format("%.3f")
            + ",\"az\":" + az.format("%.3f")
            + ",\"gx\":" + gx.format("%.3f")
            + ",\"gy\":" + gy.format("%.3f")
            + ",\"gz\":" + gz.format("%.3f")
            + ",\"mx\":" + mx.format("%.2f")
            + ",\"my\":" + my.format("%.2f")
            + ",\"mz\":" + mz.format("%.2f")
            + ",\"hr\":" + hr.toString()
            + "}";
    }

    private static function _serializeGps(g as Dictionary) as String {
        var lat = (g.get("lat") != null ? g.get("lat") : 0.0)  as Double;
        var lon = (g.get("lon") != null ? g.get("lon") : 0.0)  as Double;
        var alt = (g.get("alt") != null ? g.get("alt") : 0.0f) as Float;
        var spd = (g.get("spd") != null ? g.get("spd") : 0.0f) as Float;
        var hdg = (g.get("hdg") != null ? g.get("hdg") : 0.0f) as Float;
        var acc = (g.get("acc") != null ? g.get("acc") : 0.0f) as Float;
        var ts  = (g.get("ts")  != null ? g.get("ts")  : 0l)   as Long;

        return "{\"lat\":" + lat.format("%.6f")
            + ",\"lon\":" + lon.format("%.6f")
            + ",\"alt\":" + alt.format("%.1f")
            + ",\"spd\":" + spd.format("%.2f")
            + ",\"hdg\":" + hdg.format("%.1f")
            + ",\"acc\":" + acc.format("%.1f")
            + ",\"ts\":"  + ts.toString()
            + "}";
    }

    private static function _truncateToMaxSize(
        sessionId   as String,
        packetIndex as Number,
        deviceTime  as Number,
        battery     as Number,
        ef          as Number
    ) as String {
        return "{\"pv\":" + PROTOCOL_VERSION.toString()
            + ",\"sid\":\"" + sessionId + "\""
            + ",\"pi\":"    + packetIndex.toString()
            + ",\"dtr\":"   + deviceTime.toString()
            + ",\"s\":[]"
            + ",\"meta\":{\"bat\":" + battery.toString() + "}"
            + ",\"ef\":"    + ef.toString()
            + "}";
    }
}
