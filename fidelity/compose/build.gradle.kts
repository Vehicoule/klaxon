// klaxon-fidelity-compose — the Compose side of the pixel-fidelity harness.
// It renders the SAME fidelity/scenes.json the Klaxon runner consumes as
// real Material 3 composables (Button/IconButton/Checkbox/…, not the
// conformance DSL's generic nodes) into a headless Skiko raster surface via
// androidx.compose.ui.ImageComposeScene, writing
// fidelity/out/compose/<scene_id>.ppm for tools/fidelity_diff.py.
//
// Why a separate project from conformance/runners/compose: the fidelity
// matrix exercises M3 Expressive APIs (expressive button/icon-button
// variants, PrimaryTabRow, …) that only exist in the JB Compose
// 1.13.0-alpha line (androidx m3 ~1.5 alpha). The conformance runner stays
// pinned at 1.8.2 — the 1.13 ComposeScene API changed
// (CanvasLayersComposeScene takes a FrameRecomposer, render() became
// draw()+measureAndLayout()) and would not compile there.
//
// Version pins (see fidelity/README.md):
//   JB Compose plugin   1.13.0-alpha02  (bundles androidx m3 ~1.5.0-alpha)
//   Kotlin              2.2.21          (the line the plugin is built for)
//   kotlinx-serialization 1.9.0         (scenes.json parsing)
//   kotlinx-coroutines    1.10.2        (ImageComposeScene's composition ctx)

plugins {
    kotlin("jvm") version "2.2.21"
    kotlin("plugin.serialization") version "2.2.21"
    id("org.jetbrains.compose") version "1.13.0-alpha02"
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21"
    application
}

group = "klaxon.fidelity"
version = "1.0.0"

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("conf.compose.SceneMainKt")
}

sourceSets {
    main {
        // The pinned font the Klaxon side uses via KLAXON_FONT_DIR — pulled
        // straight from the repo's vendored copy, loaded as a classpath
        // resource by ResourceFont("DejaVuSans.ttf").
        resources.srcDir("../../deps/fonts")
    }
}

dependencies {
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
}

tasks.register<Jar>("fatJar") {
    group = "build"
    description = "Assembles a runnable fat jar (macOS arm64 Skiko natives only)."
    archiveFileName.set("klaxon-fidelity-compose-all.jar")
    manifest {
        attributes("Main-Class" to "conf.compose.SceneMainKt")
    }
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE
    from(sourceSets.main.get().output)
    from(configurations.runtimeClasspath.get().map { if (it.isDirectory) it else zipTree(it) })
    exclude(
        "skiko/libs/linux-x64/**",
        "skiko/libs/windows-x64/**",
        "skiko/libs/macos-x64/**",
        "dejavu-fonts-ttf-2.37.zip",
    )
}
