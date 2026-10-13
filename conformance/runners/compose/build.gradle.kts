// klaxon-conformance-compose — the Compose Multiplatform conformance runner
// (roadmap Phase 4c.7 port). A JVM port of Klaxon's conformance harness
// (src/conformance.zig + src/conformance_main.zig): it executes the same
// framework-neutral vectors under conformance/tests/ and emits the same
// JSON report shape (framework: "compose").
//
// The runner is a plain Kotlin/JVM program: it drives
// androidx.compose.ui.scene.CanvasLayersComposeScene headlessly into a CPU
// raster Skiko surface (no window, no GPU, no vsync). See MAPPING.md for the
// DSL → Compose mapping and the documented approximations.

plugins {
    kotlin("jvm") version "2.1.21"
    id("org.jetbrains.compose") version "1.8.2"
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.21"
    application
}

group = "klaxon.conformance"
version = "1.0.0"

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("conf.compose.MainKt")
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.foundation)
    implementation(compose.material3)
}

tasks.register<Jar>("fatJar") {
    group = "build"
    description = "Assembles a runnable fat jar (macOS arm64 Skiko natives only)."
    archiveFileName.set("klaxon-conformance-compose-all.jar")
    manifest {
        attributes("Main-Class" to "conf.compose.MainKt")
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
