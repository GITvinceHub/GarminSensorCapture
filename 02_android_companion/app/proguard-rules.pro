# ProGuard rules for SensorCapture
# minifyEnabled is false in release build — these rules are placeholders.

-keepattributes Signature
-keepattributes *Annotation*

# Gson
-keep class com.garmin.sensorcapture.models.** { *; }
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# Connect IQ SDK
-keep class com.garmin.android.connectiq.** { *; }
-dontwarn com.garmin.android.connectiq.**

# Kotlin coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
