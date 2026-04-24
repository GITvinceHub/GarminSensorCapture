package com.garmin.sensorcapture.models

import com.google.gson.annotations.SerializedName

/**
 * Root packet received from the Garmin watch via Connect IQ channel (protocol v1).
 *
 * Implements contracts C-060..C-061 per SPECIFICATION.md §7.7.
 *
 * See SPECIFICATION.md §8.1 (data packet), §8.2 (header), §8.3 (footer).
 *
 * Nullability discipline (CRITICAL, fixes v1.3.x NPE crash — SC-002):
 * Gson ignores Kotlin's non-null annotations and will set a field to null when the
 * corresponding JSON key is absent. The watch emits header/footer packets WITHOUT
 * the `s` field and data packets MAY omit `sid` in rare edge cases, so every
 * reference-type field that can be absent on the wire MUST be declared nullable
 * here. Use [samplesOrEmpty] / [isMetaPacket] to work with samples safely.
 */
data class GarminPacket(
    @SerializedName("pv")   val protocolVersion: Int = 1,
    @SerializedName("sid")  val sessionId: String?        = null,   // nullable: gson sets null if absent
    @SerializedName("pi")   val packetIndex: Long         = 0L,
    @SerializedName("dtr")  val deviceTimeReference: Long = 0L,
    @SerializedName("s")    val samples: List<SensorSample>? = null, // nullable: absent in header/footer (SC-002)
    @SerializedName("rr")   val rrIntervals: List<Int>?   = null,
    @SerializedName("gps")  val gps: GpsData?             = null,
    @SerializedName("meta") val meta: MetaData?           = null,
    @SerializedName("ef")   val errorFlags: Int           = 0,
    @SerializedName("pt")   val packetType: String?       = null,   // "header" | "footer" | null (data)
    @SerializedName("user") val user: Map<String, Any?>?  = null,
    @SerializedName("device")  val device: Map<String, Any?>? = null,
    @SerializedName("history") val history: Map<String, Any?>? = null
) {
    // ── Error flag decoders (§8.6) ────────────────────────────────────
    /** True if the SENSOR_ERROR bit (0x01) is set. */
    val hasSensorError: Boolean    get() = errorFlags and 0x01 != 0
    /** True if the GPS_ERROR bit (0x02) is set. */
    val hasGpsError: Boolean       get() = errorFlags and 0x02 != 0
    /** True if the BUFFER_OVERFLOW bit (0x04) is set. */
    val hasBufferOverflow: Boolean get() = errorFlags and 0x04 != 0
    /** True if the PARTIAL_PACKET bit (0x08) is set. */
    val isPartial: Boolean         get() = errorFlags and 0x08 != 0
    /** True if the CLOCK_SKEW bit (0x10) is set. */
    val hasClockSkew: Boolean      get() = errorFlags and 0x10 != 0
    /** True if the COMM_RETRY bit (0x20) is set. */
    val isRetransmit: Boolean      get() = errorFlags and 0x20 != 0

    // ── Meta helpers (C-061) ──────────────────────────────────────────
    /** True if this packet carries session metadata (header or footer), not sensor samples. */
    val isMetaPacket: Boolean get() = !packetType.isNullOrEmpty()

    /** Samples as a guaranteed non-null list. Empty for meta packets. */
    val samplesOrEmpty: List<SensorSample> get() = samples ?: emptyList()

    companion object {
        /** Current protocol version (SPECIFICATION.md §8.1). */
        const val PROTOCOL_VERSION_CURRENT = 1
    }
}

/**
 * Single IMU + HR sample within a data packet (SPECIFICATION.md §8.1).
 *
 * Field [t] is a PER-SAMPLE PERIOD in milliseconds (not a cumulative offset).
 * At 100 Hz, t ≈ 10. Re-constructing absolute timestamps requires cumulative
 * summation from the packet's dtr — handled downstream in the Python parser.
 */
data class SensorSample(
    @SerializedName("t")  val t: Long   = 0L,   // per-sample period (ms) — NOT an offset
    @SerializedName("ax") val ax: Float = 0f,   // Accel X (milli-g)
    @SerializedName("ay") val ay: Float = 0f,   // Accel Y (milli-g)
    @SerializedName("az") val az: Float = 0f,   // Accel Z (milli-g)
    @SerializedName("gx") val gx: Float = 0f,   // Gyro X (deg/s)
    @SerializedName("gy") val gy: Float = 0f,   // Gyro Y (deg/s)
    @SerializedName("gz") val gz: Float = 0f,   // Gyro Z (deg/s)
    @SerializedName("mx") val mx: Float = 0f,   // Mag X (µT) — 0 when sub-sampled
    @SerializedName("my") val my: Float = 0f,
    @SerializedName("mz") val mz: Float = 0f,
    @SerializedName("hr") val hr: Int   = 0     // Heart rate (bpm), 0 = unavailable
) {
    /** Accelerometer magnitude in milli-g. */
    val accelMagnitude: Float
        get() = kotlin.math.sqrt((ax * ax + ay * ay + az * az).toDouble()).toFloat()
}

/**
 * GPS data snapshot associated with a packet (SPECIFICATION.md §8.1).
 *
 * All trailing fields are nullable because the watch sometimes emits GPS rows
 * with only a fix position and no velocity / heading.
 */
data class GpsData(
    @SerializedName("lat") val lat: Double = 0.0,
    @SerializedName("lon") val lon: Double = 0.0,
    @SerializedName("alt") val alt: Float? = null,
    @SerializedName("spd") val spd: Float? = null,
    @SerializedName("hdg") val hdg: Float? = null,
    @SerializedName("acc") val acc: Float? = null,
    @SerializedName("ts")  val ts: Long    = 0L
) {
    /** GPS timestamp in milliseconds (wire format gives seconds). */
    val timestampMs: Long get() = ts * 1000L

    /** True if latitude and longitude are within valid ranges. */
    val isValid: Boolean get() = lat in -90.0..90.0 && lon in -180.0..180.0 && !(lat == 0.0 && lon == 0.0)
}

/**
 * Device metadata included in data packets (SPECIFICATION.md §8.1).
 *
 * Only [bat] is REQUIRED by contract C-020; the others are best-effort.
 */
data class MetaData(
    @SerializedName("bat")       val bat: Int?        = null,   // battery %
    @SerializedName("pres_pa")   val pressurePa: Int? = null,   // pressure (Pa)
    @SerializedName("temp_c")    val temp: Float?     = null,   // °C (internal temp)
    @SerializedName("spo2")      val spo2: Int?       = null,
    @SerializedName("stress")    val stress: Int?     = null,
    @SerializedName("body_batt") val bodyBattery: Int? = null
)

/**
 * Enriched packet as stored in the JSONL file — adds Android reception metadata.
 * See SPECIFICATION.md §8.5.
 */
data class ReceivedPacket(
    val receivedAt: String,  // ISO-8601 UTC of Android reception
    val sessionId: String,   // redundant copy of sid for fast indexing
    val packet: GarminPacket
)
