# Consumer rules for R8/ProGuard.
#
# R8 reads META-INF/proguard/* out of dependency jars, so an Android app that shrinks its release
# build gets these automatically — no copy-paste into the app's proguard-rules.pro, and no
# "messages decode fine in debug and throw SerializationException in release" bug report.
#
# kotlinx.serialization resolves a class's serializer through a synthetic $$serializer field and a
# Companion.serializer() method. Both are only reachable reflectively, so R8 sees them as dead.

-keepattributes *Annotation*, InnerClasses, Signature, RuntimeVisible*Annotations

# Keep the generated serializer of every @Serializable type in this SDK.
-if @kotlinx.serialization.Serializable class com.cyaim.im.client.**
-keepclassmembers class com.cyaim.im.client.<1> {
    static **$* *;
}
-keepclassmembers class com.cyaim.im.client.**$* extends kotlinx.serialization.KSerializer {
    static <1>$<2> INSTANCE;
}
-keepclassmembers class com.cyaim.im.client.** {
    *** Companion;
}
-keepclasseswithmembers class com.cyaim.im.client.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Enum entries are matched by name when decoding, and by ordinal never. This covers the enums that
# are genuinely closed — KickReason, ConnectionState, ImLogLevel — not the wire enumerations, which
# are value classes over an int (see Enums.kt) precisely so an unknown member keeps its number.
-keepclassmembers enum com.cyaim.im.client.** {
    <fields>;
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# The open-enum codecs. Each is a top-level object named in a @Serializable(with = ...) argument and
# reached through its INSTANCE field; losing one turns every message of that type into a decode
# failure in release builds only, which is the worst kind of bug report to receive.
-keepclassmembers class com.cyaim.im.client.** implements kotlinx.serialization.KSerializer {
    public static ** INSTANCE;
}

# OkHttp's own optional dependencies, which it references but does not require at runtime.
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
