# ── Ugam Booking — R8/ProGuard keep rules for release ───────────────────
#
# Dart code is AOT-compiled and untouched by R8; these rules only guard the
# Java/Kotlin (engine + plugin) layer that R8 shrinks/obfuscates.

# Flutter engine + plugin entry points (reflection-loaded).
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# Keep metadata R8 needs to not break Kotlin/reflection-y plugin code.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod, Exceptions
-keep class kotlin.Metadata { *; }

# Play Core / deferred components — Flutter's embedding references these even
# when unused; without these keeps R8 full-mode fails with "missing class".
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

# OkHttp / Okio / Conscrypt — pulled in transitively by networking; optional
# classes that R8 warns about but aren't present.
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
