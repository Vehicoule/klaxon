// klaxon-bench-compose — the Compose Multiplatform comparison benchmark runner
// (roadmap Phase 4c.4). A JVM port of Klaxon's own bench (src/bench.zig +
// src/bench_main.zig): the same 9 scenes, the same harness settings, the same
// JSON report. See README.md for the methodology.
//
// The runner is a plain Kotlin/JVM program (Compose Multiplatform Desktop
// without a multiplatform module): it drives
// androidx.compose.ui.scene.CanvasLayersComposeScene headlessly into a CPU
// raster Skiko surface (no window, no GPU, no vsync) — see src/main/kotlin.

plugins {
    kotlin("jvm") version "2.1.21"
    id("org.jetbrains.compose") version "1.8.2"
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.21"
}

group = "klaxon.bench"
version = "1.0.0"

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.foundation)
    implementation(compose.material3)
}

// A single runnable jar (the runner is executed with `java -jar`; see run.sh).
// Only the host platform's Skiko natives are kept — the other platforms'
// natives (linux-x64 / windows-x64 / macos-x64) are dead weight in the jar.
tasks.register<Jar>("fatJar") {
    group = "build"
    description = "Assembles a runnable fat jar (macOS arm64 Skiko natives only)."
    archiveFileName.set("klaxon-bench-compose-all.jar")
    manifest {
        attributes("Main-Class" to "bench.compose.BenchKt")
    }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(sourceSets.main.get().output)
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) })
    exclude(
        "skiko/libs/linux-x64/**",
        "skiko/libs/windows-x64/**",
        "skiko/libs/macos-x64/**",
    )
}
