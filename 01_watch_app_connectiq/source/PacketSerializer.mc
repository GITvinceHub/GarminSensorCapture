import Toybox.Lang;
import Toybox.System;

//! Serializes sensor data batches into compact JSON strings
//! conforming to protocol v1.
//!
//! Max output size: 4096 characters.
//! Keys are abbreviated to minimize BLE payload size.
class PacketSerializer {

    //! Error flag constants (bitmask)
    static const EF_SENSOR_ERROR    = 0x01;
    static const EF_GPS_ERROR       = 0x02;
    static const EF_BUFFER_OVERFLOW = 0x04;
    static const EF_PARTIAL_PACKET  = 0x08;
    static const EF_CLOCK_SKEW      = 0x10;
    static const EF_COMM_RETRY      = 0x20;

    //! Maximum serialized packet size in characters
    static const MAX_PACKET_SIZE = 4096;

    //! Protocol version
    static const PROTOCOL_VERSION = 1;

    //! Serialize a complete sensor packet to JSON string.
    //! @param sessionId    Session ID string
    //! @param packetIndex  Monotonic packet counter
    //! @param deviceTime   System.getTimer() value at serialization time
    //! @param samples      Array of sample dictionaries
    //! @param rrIntervals  Array of RR intervals (ms) for this batch, or null
    //! @param gpsData      GPS dictionary (may be null)
    //! @param metaDict     Dictionary of meta fields (bat required; spo2, pres_pa,
    //!                     alt_baro_m, temp_c, cadence, power_w, heading_rad,
    //!                     resp, stress, body_batt, steps_day, dist_day_m,
    //!                     floors_day optional)
    //! @param errorFlags   Initial error flags bitmask
    //! @return JSON string ≤ MAX_PACKET_SIZE chars, or null on fatal error
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
            // ── Build samples array ─────────────────────────────────
            var samplesJson = _serializeSamples(samples, MAX_PACKET_SIZE);
            var samplesStr  = samplesJson.get("json") as String;
            var countUsed   = samplesJson.get("count") as Number;

            if (countUsed < samples.size()) {
                ef |= EF_PARTIAL_PACKET;
            }

            // ── Build GPS object ────────────────────────────────────
            var gpsStr = "";
            if (gpsData != null) {
                gpsStr = _serializeGps(gpsData as Dictionary);
            }

            // ── Build meta object from dict ─────────────────────────
            var metaStr = _serializeMeta(metaDict);

            // ── Build RR intervals array ────────────────────────────
            var rrStr = "";
            if (rrIntervals != null && rrIntervals.size() > 0) {
                rrStr = "[";
                for (var i = 0; i < rrIntervals.size(); i++) {
                    if (i > 0) { rrStr += ","; }
                    rrStr += rrIntervals[i].toString();
                }
                rrStr += "]";
            }

            // ── Assemble root object ────────────────────────────────
            var battery = (metaDict.get("bat") != null) ? metaDict.get("bat") as Number : 0;
            json = "{";
            json += "\"pv\":" + PROTOCOL_VERSION.toString() + ",";
            json += "\"sid\":\"" + sessionId + "\",";
            json += "\"pi\":" + packetIndex.toString() + ",";
            json += "\"dtr\":" + deviceTime.toString() + ",";
            json += "\"s\":" + samplesStr + ",";

            if (rrStr.length() > 0) {
                json += "\"rr\":" + rrStr + ",";
            }
            if (gpsStr.length() > 0) {
                json += "\"gps\":" + gpsStr + ",";
            }

            json += "\"meta\":" + metaStr + ",";
            json += "\"ef\":" + ef.toString();
            json += "}";

            // ── Size guard ──────────────────────────────────────────
            if (json.length() > MAX_PACKET_SIZE) {
                ef |= EF_PARTIAL_PACKET;
                json = _truncateToMaxSize(
                    sessionId, packetIndex, deviceTime, battery, ef
                );
            }

        } catch (ex instanceof Lang.Exception) {
            System.println("PacketSerializer: exception: " + ex.getErrorMessage());
            return null;
        }

        return json;
    }

    //! Serialize a session header packet — sent once at session start.
    //! Contains user profile, device info, and (capped) sensor histories.
    //! Uses a separate packet type `pt:"header"` so consumers can discriminate.
    //!
    //! @param sessionId    Session ID string
    //! @param deviceTime   System.getTimer() value at header build time
    //! @param userProfile  Dict with weight_g, height_cm, birth_year, gender, hr_max, hr_zones (all optional)
    //! @param deviceInfo   Dict with model, firmware, app_version (optional)
    //! @param histories    Dict of history arrays keyed by name (e.g. "hr", "spo2", "stress")
    //! @return JSON string ≤ MAX_PACKET_SIZE chars, or null on error
    static function serializeHeaderPacket(
        sessionId   as String,
        deviceTime  as Number,
        userProfile as Dictionary,
        deviceInfo  as Dictionary,
        histories   as Dictionary
    ) as String or Null {
        try {
            var json = "{";
            json += "\"pv\":" + PROTOCOL_VERSION.toString() + ",";
            json += "\"pt\":\"header\",";
            json += "\"sid\":\"" + sessionId + "\",";
            json += "\"pi\":0,";
            json += "\"dtr\":" + deviceTime.toString();

            // user profile
            if (userProfile != null && userProfile.size() > 0) {
                json += ",\"user\":" + _serializeFlatDict(userProfile);
            }
            // device info
            if (deviceInfo != null && deviceInfo.size() > 0) {
                json += ",\"device\":" + _serializeFlatDict(deviceInfo);
            }

            // histories: each is an array of [ts_s, value] pairs
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

            // If we overflowed, return a minimal header with empty history.
            if (json.length() > MAX_PACKET_SIZE) {
                json = "{\"pv\":" + PROTOCOL_VERSION.toString()
                     + ",\"pt\":\"header\""
                     + ",\"sid\":\"" + sessionId + "\""
                     + ",\"pi\":0"
                     + ",\"dtr\":" + deviceTime.toString()
                     + ",\"history\":{},\"trunc\":true}";
            }

            return json;
        } catch (ex instanceof Lang.Exception) {
            System.println("PacketSerializer: header serialization failed: " + ex.getErrorMessage());
            return null;
        }
    }

    //! Serialize a Dictionary as flat JSON (no nested objects, scalar values only).
    private static function _serializeFlatDict(d as Dictionary) as String {
        var out = "{";
        var keys = d.keys() as Array;
        for (var i = 0; i < keys.size(); i++) {
            var k = keys[i] as String;
            var v = d.get(k);
            if (v == null) { continue; }
            if (i > 0 && out.length() > 1) { out += ","; }
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

    //! Serialize the meta Dictionary, preserving field order with "bat" first.
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

    //! Serialize a history array (list of [ts_s, value] pairs), stopping
    //! before sizeBudget characters are consumed. Values are numeric.
    private static function _serializeHistoryArray(arr as Array, sizeBudget as Number) as String {
        var out = "[";
        var used = 1;
        for (var i = 0; i < arr.size(); i++) {
            var entry = arr[i] as Array;
            if (entry == null || entry.size() < 2) { continue; }
            var ts = entry[0];
            var v  = entry[1];
            var pair = "[" + ts.toString() + "," + v.toString() + "]";
            var needed = pair.length() + (i > 0 ? 1 : 0);
            if (used + needed + 1 > sizeBudget) { break; }
            if (i > 0 && out.length() > 1) { out += ","; used += 1; }
            out += pair;
            used += pair.length();
        }
        out += "]";
        return out;
    }

    //! Serialize the samples array, stopping before MAX_PACKET_SIZE.
    //! @param samples Array of sample dicts
    //! @param sizeLimit Maximum characters for the entire packet
    //! @return Dictionary {"json": String, "count": Number}
    private static function _serializeSamples(
        samples   as Array<Dictionary>,
        sizeLimit as Number
    ) as Dictionary {

        // Reserve space for envelope fields (~200 chars)
        var remainingBudget = sizeLimit - 250;
        var samplesStr = "[";
        var count = 0;

        for (var i = 0; i < samples.size(); i++) {
            var sampleStr = _serializeSample(samples[i] as Dictionary);

            // Check if adding this sample would exceed budget
            var needed = sampleStr.length() + (i > 0 ? 1 : 0) + 1; // +comma +]
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

    //! Serialize a single sample to JSON.
    //! @param s Sample dictionary
    //! @return JSON fragment string
    private static function _serializeSample(s as Dictionary) as String {
        var t  = (s.get("t")  != null ? s.get("t")  : 0) as Number;
        var ax = (s.get("ax") != null ? s.get("ax") : 0.0f) as Float;
        var ay = (s.get("ay") != null ? s.get("ay") : 0.0f) as Float;
        var az = (s.get("az") != null ? s.get("az") : 0.0f) as Float;
        var gx = (s.get("gx") != null ? s.get("gx") : 0.0f) as Float;
        var gy = (s.get("gy") != null ? s.get("gy") : 0.0f) as Float;
        var gz = (s.get("gz") != null ? s.get("gz") : 0.0f) as Float;
        var mx = (s.get("mx") != null ? s.get("mx") : 0.0f) as Float;
        var my = (s.get("my") != null ? s.get("my") : 0.0f) as Float;
        var mz = (s.get("mz") != null ? s.get("mz") : 0.0f) as Float;
        var hr = (s.get("hr") != null ? s.get("hr") : 0) as Number;

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

    //! Serialize GPS data dictionary to JSON.
    //! @param g GPS dictionary
    //! @return JSON fragment string
    private static function _serializeGps(g as Dictionary) as String {
        var lat = (g.get("lat") != null ? g.get("lat") : 0.0) as Double;
        var lon = (g.get("lon") != null ? g.get("lon") : 0.0) as Double;
        var alt = (g.get("alt") != null ? g.get("alt") : 0.0f) as Float;
        var spd = (g.get("spd") != null ? g.get("spd") : 0.0f) as Float;
        var hdg = (g.get("hdg") != null ? g.get("hdg") : 0.0f) as Float;
        var acc = (g.get("acc") != null ? g.get("acc") : 0.0f) as Float;
        var ts  = (g.get("ts")  != null ? g.get("ts")  : 0l) as Long;

        return "{\"lat\":" + lat.format("%.6f")
            + ",\"lon\":" + lon.format("%.6f")
            + ",\"alt\":" + alt.format("%.1f")
            + ",\"spd\":" + spd.format("%.2f")
            + ",\"hdg\":" + hdg.format("%.1f")
            + ",\"acc\":" + acc.format("%.1f")
            + ",\"ts\":" + ts.toString()
            + "}";
    }

    //! Build a minimal packet when full packet would exceed size limit.
    //! @return Minimal JSON string with error flags
    private static function _truncateToMaxSize(
        sessionId   as String,
        packetIndex as Number,
        deviceTime  as Number,
        battery     as Number,
        ef          as Number
    ) as String {
        return "{\"pv\":" + PROTOCOL_VERSION.toString()
            + ",\"sid\":\"" + sessionId + "\""
            + ",\"pi\":" + packetIndex.toString()
            + ",\"dtr\":" + deviceTime.toString()
            + ",\"s\":[]"
            + ",\"meta\":{\"bat\":" + battery.toString() + "}"
            + ",\"ef\":" + ef.toString()
            + "}";
    }
}
