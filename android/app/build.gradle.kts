plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The build number is the number of commits, so every commit raises the
// versionCode without editing pubspec.yaml. The pubspec's build number (or
// --build-number) still wins if it's higher. Null outside a git checkout.
val gitCommitCount: Int? = try {
    providers.exec { commandLine("git", "rev-list", "--count", "HEAD") }
        .standardOutput.asText.get().trim().toInt()
} catch (e: Exception) {
    null
}

android {
    namespace = "red.ochsenbein.voidweaver"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        }
    }

    defaultConfig {
        applicationId = "red.ochsenbein.voidweaver"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = maxOf(flutter.versionCode, gitCommitCount ?: 0)
        versionName = flutter.versionName
    }

    // Trust in the fake Subsonic server of the tests (its CA, for localhost):
    // always in debug builds (integration tests), and in a release build only
    // with -PtrustFakeServer=true, for tool/emulator_check.sh --fake-server,
    // which checks the media session of an R8-shrunk build (locally only: CI
    // doesn't run it, see docs/ANDROID.md). The release APK that's installed
    // never has it; tool/check_release_apk.sh fails if it does.
    sourceSets.getByName("debug").res.srcDir("src/fakeServer/res")
    if (providers.gradleProperty("trustFakeServer").orNull == "true") {
        sourceSets.getByName("release") {
            res.srcDir("src/fakeServer/res")
            manifest.srcFile("src/fakeServer/AndroidManifest.xml")
        }
    }

    // The release key comes from the environment (CI decodes it from a
    // secret, see docs/RELEASING.md). Without it the release build is signed
    // with the debug key, so `flutter run --release` and local checks work;
    // such an APK can't update an installed release, and tool/check_apk_signature.sh
    // rejects it.
    val releaseKeystore = System.getenv("VOIDWEAVER_KEYSTORE_FILE")?.takeIf { it.isNotBlank() }
    if (releaseKeystore != null) {
        signingConfigs.create("release") {
            storeFile = file(releaseKeystore)
            storePassword = System.getenv("VOIDWEAVER_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("VOIDWEAVER_KEY_ALIAS")
            keyPassword = System.getenv("VOIDWEAVER_KEY_PASSWORD")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeystore != null) "release" else "debug")
        }
    }
}

flutter {
    source = "../.."
}
