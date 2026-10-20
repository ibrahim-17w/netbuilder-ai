import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// A tagged build supplies android/key.properties and the keystore through CI
// secrets. Local builds keep the debug signing config so `flutter run
// --release` still works without a private key on a developer machine.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseKeystore) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "com.netbuilder.net_builder"
    // flutter_plugin_android_lifecycle requires consumers to compile
    // against API 36; pin it explicitly so a pinned plugin cannot drag it
    // back down and fail the AAR metadata check.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.netbuilder.net_builder"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                    ?: error("keyAlias is missing from android/key.properties")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                    ?: error("keyPassword is missing from android/key.properties")
                storeFile = file(
                    keystoreProperties.getProperty("storeFile")
                        ?: error("storeFile is missing from android/key.properties"),
                )
                storePassword = keystoreProperties.getProperty("storePassword")
                    ?: error("storePassword is missing from android/key.properties")
            }
        }
    }

    buildTypes {
        release {
            // A tag build must be signed with the release key; local builds
            // without key.properties keep the debug key so they still run.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
