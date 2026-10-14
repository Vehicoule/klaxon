// klaxon-bench-compose-android — top-level build file.
//
// Plugin versions are pinned to what this repo already uses so the Gradle
// cache in ~/.gradle is reused: AGP 8.7.3 (android/build.gradle), Kotlin
// 2.1.21 + the compose-compiler Gradle plugin (bench/runners/compose).

plugins {
    id("com.android.application") version "8.7.3" apply false
    kotlin("android") version "2.1.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.21" apply false
}
