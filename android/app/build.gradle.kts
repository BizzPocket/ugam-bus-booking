import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config is read from android/key.properties, which is
// git-ignored and never committed. When the file is absent (e.g. a fresh
// clone or CI without secrets) the release build falls back to the debug
// key so `flutter run --release` still works locally. Store uploads MUST
// be built on a machine where key.properties + the keystore are present.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystore = keystorePropertiesFile.exists()
if (hasKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.occubitsolution.ugambooking"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (uses java.time on older APIs).
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.occubitsolution.ugambooking"
        minSdk = maxOf(24, flutter.minSdkVersion)
        // Google Play requires new apps/updates to target a recent API level.
        // Pinned explicitly so the target doesn't drift with the Flutter SDK.
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasKeystore) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // A real upload keystore is REQUIRED to sign a release artifact. When
            // key.properties is absent we still assign the debug config here as a
            // configuration-time placeholder so DEBUG builds keep configuring, but
            // the taskGraph guard below ABORTS the build before any release
            // artifact is produced — we never silently debug-sign a store upload.
            signingConfig = if (hasKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Shrink + obfuscate the Java/Kotlin (plugin/engine) layer and
            // strip unused Android resources for a smaller, harder-to-reverse
            // store build. Dart is AOT-compiled and unaffected; the keep rules
            // in proguard-rules.pro guard the reflection-using bits.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// Fail loudly instead of debug-signing a release. If a release artifact
// (assembleRelease / bundleRelease) is in the resolved task graph but no upload
// keystore is configured, abort the build: a debug-signed AAB/APK is rejected by
// the Play Store, and nothing else here fails on its own. DEBUG builds have no
// release task in the graph, so they are unaffected.
gradle.taskGraph.whenReady {
    val assemblingRelease = allTasks.any { task ->
        task.name.contains("Release") &&
            (task.name.startsWith("assemble") || task.name.startsWith("bundle"))
    }
    if (assemblingRelease && !hasKeystore) {
        throw GradleException(
            "Release build aborted: android/key.properties and the upload keystore " +
                "are missing, so this artifact would be debug-signed and rejected by " +
                "the Play Store. Provide key.properties + the keystore, or build a " +
                "debug variant instead."
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Core library desugaring backport, required by flutter_local_notifications.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
