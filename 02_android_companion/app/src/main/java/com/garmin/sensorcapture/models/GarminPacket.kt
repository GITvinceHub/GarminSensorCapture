package com.garmin.sensorcapture.models

import com.google.gson.annotations.SerializedName

/**
 * Root packet received from the Garmin watch via Connect IQ channel.
 * Fields use abbreviated JSON names (protocol v1).
 */
data class GarminPacket(
    @SerializedName("pv")  val protocolVersion: Int,
    @SerializedName("sid") val sessionId: String,
    @SerializedName("pi")  val packetIndex: Long,
    @SerializedName("dtr") val deviceTimeReference: Long,
    @SerializedName("s")   val samples: List<SensorSample>,
    @SerializedName("gps") val gps: GpsData?,
    @SerializedName("meta") val meta: MetaData?,
    @SerializedName("ef")  val errorFlags: Int = 0
) {
    /** True if the SENSOR_ERROR bit is set in errorFlags */
    val hasSensorError: Boolean get() = errorFlags and 0x01 != 0
    /** True if the GPS_ERROR bit is set */
    val hasGpsError: Boolean get() = errorFlags and 0x02 != 0
    /** True if the BUFFER_OVERFLOW bit is set */
    val hasBufferOverflow: Boolean get() = errorFlags and 0x04 != 0
    /** True if the PARTIAL_PACKET bit is set */
    val isPartial: Boolean get() = errorFlags and 0x08 != 0

    companion object {
        const val PROTOCOL_VERSION_CURRENT = 1
    }
}

/**
 * Single IMU + HR sample within a packet.
 * Time offset [t] is in milliseconds relative to the packet's deviceTimeReference.
 * Accelerometer values are in milli-g; gyroscope in deg/s; magnetometer in µT.
 */
data class SensorSample(
    @SerializedName("t")  val t: Long,          // Time offset ms from dtr
    @SerializedName("ax") val ax: Float,         // Accel X (milli-g)
    @SerializedName("ay") val ay: Float,         // Accel Y (milli-g)
    @SerializedName("az") val az: Float,         // Accel Z (milli-g)
    @SerializedName("gx") val gx: Float,         // Gyro X (deg/s)
    @SerializedName("gy") val gy: Float,         // Gyro Y (deg/s)
    @SerializedName("gz") val gz: Float,         // Gyro Z (deg/s)
    @SerializedName("mx") val mx: Float = 0f,    // Mag X (µT)
    @SerializedName("my") val my: Float = 0f,    // Mag Y (µT)
    @SerializedName("mz") val mz: Float = 0f,    // Mag Z (µT)
    @SerializedName("hr") val hr: Int = 0        // Heart rate (bpm), 0 = unavailable
) {
    /** Absolute Unix timestamp in milliseconds, computed from packet dtr + offset */
    fun absoluteTimestampMs(deviceTimeReference: Long): Long = deviceTimeReference + t

    /** Accelerometer magnitude in milli-g */
    val accelMagnitude: Float get() = Math.sqrt(
        (ax * ax + ay * ay + az * az).toDouble()
    ).toFloat()
}

/**
 * GPS data snapshot associated with a packet.
 * lat/lon in decimal degrees (WGS84); alt in meters; spd in m/s; hdg in degrees; acc in meters.
 */
data class GpsData(
    @SerializedName("lat") val lat: Double,      // Latitude (decimal degrees)
    @SerializedName("lon") val lon: Double,      // Longitude (decimal degrees)
    @SerializedName("alt") val alt: Float?,      // Altitude MSL (meters)
    @SerializedName("spd") val spd: Float?,      // Speed (m/s)
    @SerializedName("hdg") val hdg: Float?,      // Heading (degrees, 0=North)
    @SerializedName("acc") val acc: Float?,      // Horizontal accuracy (meters CEP)
    @SerializedName("ts")  val ts: Long          // GPS Unix timestamp (seconds)
) {
    /** GPS timestamp in milliseconds */
    val timestampMs: Long get() = ts * 1000L

    /** True if latitude and longitude are within valid ranges */
    val isValid: Boolean get() = lat in -90.0..90.0 && lon in -180.0..180.0
}

/**
 * Device metadata included in each packet.
 */
data class MetaData(
    @SerializedName("bat")  val bat: Int?,       // Battery level (%)
    @SerializedName("temp") val temp: Float?     // Internal temperature (°C)
)

/**
 * Enriched packet as stored in the JSONL file — adds Android reception metadata.
 */
data class ReceivedPacket(
    val receivedAt: String,        // ISO8601 UTC timestamp of Android reception
    val sessionId: String,         // Redundant copy of sid for quick indexing
    val packet: GarminPacket       // Original packet data
)
