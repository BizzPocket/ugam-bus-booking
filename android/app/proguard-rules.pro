# ── Ugam Booking — R8/ProGuard keep rules for release ───────────────────
#
# Dart code is AOT-compiled and untouched by R8; these rules only guard the
# Java/Kotlin (engine + plugin) layer that R8 shrinks/obfuscates.

# Flutter engine + plugin entry points (reflection-loaded).
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# printing / pdf — the seat-chart rasteriser behind every WhatsApp
# `seat_allotment` image header. NOT covered by the io.flutter.** keeps above:
# the plugin lives under net.nfet.flutter.printing, and it ships PdfConvert in
# the FRAMEWORK's own `android.print` package, which R8 will happily strip or
# rename. When that happens the release APK renders no chart, the send falls
# back to a header-less template, and Meta rejects every recipient with
# "(#132012) Parameter format does not match" — an Android-release-only break
# that never reproduces in debug or on iOS.
-keep class net.nfet.flutter.printing.** { *; }
-keep class android.print.** { *; }
-dontwarn net.nfet.flutter.printing.**

# flutter_secure_storage — holds the Supabase refresh token; obfuscating its
# cipher/keystore classes silently drops the admin session on release builds.
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-dontwarn com.it_nomads.fluttersecurestorage.**

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
