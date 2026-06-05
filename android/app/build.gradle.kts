import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Upload-key signing config is loaded from android/key.properties at
// build time. The file is .gitignored and contains:
//
//   storeFile=upload-keystore.jks       (relative to android/app/)
//   storePassword=...
//   keyAlias=upload
//   keyPassword=...
//
// Generate the keystore once with:
//   keytool -genkey -v -keystore android/app/upload-keystore.jks \
//           -keyalg RSA -keysize 2048 -validity 10000 -alias upload
//
// When key.properties is absent (e.g. on a fresh clone, CI without
// signing secrets), `flutter build --release` falls back to the debug
// key so engineers can still build locally. Play Store rejects debug-
// signed AABs — the release-from-CI path MUST provide key.properties.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.gospelvox.gospel_vox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications 21+: the plugin uses
        // java.time APIs that aren't available below API 26, so the
        // build needs the desugar_jdk_libs shim to backport them on
        // older devices (we target minSdk 24).
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.gospelvox.gospel_vox"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the upload keystore when key.properties is
            // present (release builds for Play Store). Fall back to the
            // debug key only when the keystore is missing so engineers
            // can still `flutter run --release` locally without
            // provisioning a keystore. Production AAB upload MUST run
            // with key.properties in place — Play rejects debug-signed
            // uploads at the upload step itself.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Pairs with isCoreLibraryDesugaringEnabled above. 2.1.4 is the
    // minimum version compatible with flutter_local_notifications 21.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
