package com.garmin.sensorcapture.models

import com.google.gson.annotations.SerializedName

/**
 * Data model for packets received from the Garmin watch (protocol v1, SPEC §8).
 *
 * CRITICAL: Every reference-type field MUST be nullable.
 * This was the root cause of an NPE crash in v1.3.x when a header packet arrived
 * with no `s` field — Gson default-populated fields but non-null declarations
 * blew up downstream. The current watch (rewrite branch) emits ONLY simple data
 * packets (no header, no footer, no `pt`) per protocol v1 §8.1, but we keep the
 * model future-proof for when header/footer come back (FR-008).
 *
 * @see SPECIFICATION.md §8 Protocol, §7.7 C-060/C-061, §9 SC-002
 */
data class GarminPacket(
    @SerializedName("pv") val protocolVersion: Int? = null,
    @SerializedName("pt") val packetType: String? = null, // "header" | "footer" | null (data)
    @SerializedName("sid") val sessionId: String? = null,
    @SerializedName("pi") val packetIndex: Long? = null,
    @SerializedName("dtr") val deviceTimeReference: Long? = null, // watch uptime ms, NOT epoch
    @SerializedName("s") val samples: List<SensorSample>? = null,
    @SerializedName("rr") val rrIntervals: List<Int>? = null,
    @SerializedName("gps") val gps: GpsData? = null,
    @SerializedName("meta") val meta: MetaData? = null,
    @SerializedName("ef") val errorFlags: Int? = null,
    @SerializedName("user") val user: Map<String, Any>? = null,
    @SerializedName("device") val device: Map<String, Any>? = null,
    @SerializedName("history") val history: Map<String, Any>? = null
) {
    /** True if this is a meta (header/footer) packet — skip samples validation and NEVER ACK. */
    val isMetaPacket: Boolean
        get() = !packetType.isNullOrBlank()

    /** Samples list guaranteed non-null (empty if missing). Use this for JSONL writes. */
    val samplesOrEmpty: List<SensorSample>
        get() = samples ?: emptyList()
}

/**
 * One IMU sample in a data packet (SPEC §8.1).
 * `t` is a per-sample period (ms), NOT a cumulative offset — 10 ms at 100 Hz.
 */
data class SensorSample(
    @SerializedName("t") val t: Int? = null,       // ms — per-sample period
    @SerializedName("ax") val ax: Double? = null,  // milli-g
    @SerializedName("ay") val ay: Double? = null,
    @SerializedName("az") val az: Double? = null,
    @SerializedName("gx") val gx: Double? = null,  // deg/s
    @SerializedName("gy") val gy: Double? = null,
    @SerializedName("gz") val gz: Double? = null,
    @SerializedName("mx") val mx: Double? = null,  // µT (0 at 25 Hz undersampled slots)
    @SerializedName("my") val my: Double? = null,
    @SerializedName("mz") val mz: Double? = null,
    @SerializedName("hr") val hr: Int? = null       // bpm (0 if N/A)
)

/** GPS fix at ~1 Hz (SPEC §8.1). */
data class GpsData(
    @SerializedName("lat") val lat: Double? = null,
    @SerializedName("lon") val lon: Double? = null,
    @SerializedName("alt") val alt: Double? = null,
    @SerializedName("spd") val speed: Double? = null,
    @SerializedName("hdg") val heading: Double? = null,
    @SerializedName("acc") val accuracy: Double? = null,
    @SerializedName("ts") val timestamp: Long? = null
)

/** Metadata fields (SPEC §8.1). */
data class MetaData(
    @SerializedName("bat") val battery: Int? = null,
    @SerializedName("pres_pa") val pressurePa: Int? = null,
    @SerializedName("temp_c") val tempC: Double? = null,
    @SerializedName("spo2") val spo2: Int? = null,
    @SerializedName("stress") val stress: Int? = null,
    @SerializedName("body_batt") val bodyBattery: Int? = null
)

/**
 * A packet that has successfully passed validation in GarminReceiver
 * and is about to be logged + optionally ACKed.
 */
data class ReceivedPacket(
    val packet: GarminPacket,
    val receivedAtIsoUtc: String,
    val sessionId: String,
    val packetIndex: Long
)
