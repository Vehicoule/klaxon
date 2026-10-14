// klaxon-bench-compose-android — the Android (Jetpack Compose) benchmark runner.
// Mirrors android/settings.gradle: google + mavenCentral + gradlePluginPortal.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "KlaxonBenchCompose"
include(":app")
