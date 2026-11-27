group = "red.ochsenbein.voidweaver.player"
version = "1.0"

// Only for building the plugin on its own: in the app's build, AGP comes from
// android/settings.gradle.kts, whose version applies to this project too.
// Keep the two the same.
buildscript {
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.5.1")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

tasks.withType<JavaCompile>().configureEach {
    options.compilerArgs.addAll(listOf("-Xlint:deprecation", "-Xlint:unchecked"))
}

android {
    namespace = "red.ochsenbein.voidweaver.player"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Robolectric inflates the widget's layouts (PlayerWidgetTest). The SDK the
    // tests run on is set in src/test/resources/robolectric.properties.
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    lint {
        // Media3 marks much of what the plugin builds on @UnstableApi; the
        // check reports every use of it (193 of them), which would bury the
        // findings that matter. Media3 upgrades are checked in the emulator.
        disable += "UnsafeOptInUsageError"
        // Newer versions are Dependabot's job; these would also make the
        // output depend on the date
        disable += "GradleDependency"
        disable += "NewerVersionAvailable"
    }
}

dependencies {
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")

    // JVM tests (`./gradlew :voidweaver_player:testDebugUnitTest` in android/)
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.18.1")
}
