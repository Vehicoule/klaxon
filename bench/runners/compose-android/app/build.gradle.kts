// klaxon-bench-compose-android — the Android app module.
//
// A pure-Kotlin Jetpack Compose app (no native code): BenchmarkActivity hosts a
// full-screen ComposeView; the suite drives one scene at a time and collects
// frame work via Window.OnFrameMetricsAvailableListener (see
// java/bench/compose/Bench.kt). Same AGP/SDK pins as android/app (AGP 8.7.3,
// compileSdk 35, minSdk 26) so the toolchain + SDK pieces are already on disk.

plugins {
    id("com.android.application")
    kotlin("android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.klaxon.bench.compose"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.klaxon.bench.compose"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // The SDK debug key keeps assembleRelease installable on a local
            // emulator, like android/app does when KX_KEYSTORE is unset.
            signingConfig = signingConfigs.getByName("debug")
            // run-as / files-dir access without a debug build (bench only).
            isDebuggable = true
        }
        debug {
            isMinifyEnabled = false
        }
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    lint {
        abortOnError = false
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.06.00"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
}
