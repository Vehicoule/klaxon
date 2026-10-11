// Bench.kt — the Compose Multiplatform comparison benchmark runner (roadmap 4c.4).
//
// A JVM port of Klaxon's own benchmark (src/bench.zig + src/bench_main.zig): it
// renders the SAME 9 scenes at the SAME harness settings (640x480, 10 warmup +
// 600 measured frames, unpaced) and emits the SAME JSON report, so Klaxon
// (Zig + Skia + SDL3) and Compose Multiplatform can be compared head-to-head.
//
// Headless by construction, like Klaxon's bench: no window, no GPU, no vsync.
// The harness drives androidx.compose.ui.scene.CanvasLayersComposeScene (the
// scene API Compose itself uses for offscreen rendering) into a CPU raster
// Skiko surface and calls scene.render(...) once per frame in an unpaced loop.
// Per BaseComposeScene.render, one call runs: flush effects -> recomposition ->
// frame clock -> measure/layout -> draw — the Compose analog of Klaxon's
// tick + layout + paint, all synchronously on the calling thread.
//
// Metric definitions mirror bench.zig:
//   - fps: 1000 / frame_time_avg_ms (the loop is unpaced).
//   - frame_time_*: per-frame wall time of tick + recomposition + layout + draw,
//     measured frames only (warmup frames are rendered but not counted).
//   - ttff_ms: run start (surface + scene + composition included) -> the END of
//     the first completed frame.
//   - draw_calls_per_frame: the number of PLACED layout nodes in the scene's
//     LayoutNode tree after the final frame — Klaxon's countPaintNodes analog
//     (visible painted nodes; virtualized scenes only compose their live
//     window, matching what a real frame paints). The tree is reached through
//     the scene's RootNodeOwner (one reflective field read — see
//     countLayoutNodes; the ComposeScene interface exposes no layout-tree
//     accessor in Compose Multiplatform 1.8.2).
//   - rss_mb: process RSS via `ps -o rss= -p <pid>` (KiB -> MiB), sampled after
//     the last frame, like bench.zig samples devtools.readRssMb() after the run.
//   - frames_rendered: 610 (10 warmup + 600 measured).
@file:OptIn(InternalComposeUiApi::class)

package bench.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asComposeCanvas
import androidx.compose.ui.platform.PlatformContext
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.scene.CanvasLayersComposeScene
import androidx.compose.ui.scene.ComposeScene
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.Surface
import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.CompletableFuture
import kotlin.math.min
import kotlin.system.exitProcess

/** Harness settings — identical to bench.zig RunOptions + `-Dbench-frames=600`. */
const val WIDTH = 640
const val HEIGHT = 480
const val WARMUP_FRAMES = 10
const val MEASURED_FRAMES = 600
const val TOTAL_FRAMES = WARMUP_FRAMES + MEASURED_FRAMES

/** bench.zig BG (0x14141CFF, RRGGBBAA) as a Skia ARGB clear color. */
private val BG_ARGB = 0xFF14141C.toInt()

/// The 9 canonical scenes (bench.zig BenchScene).
enum class BenchScene(val sceneName: String) {
    HELLO("hello"),
    SCROLL_10K("scroll_10k"),
    TEXT_CJK("text_cjk"),
    GLASS_BLUR("glass_blur"),
    ANIM_100("anim_100"),
    GALLERY("gallery"),
    RESIZE("resize"),
    INPUT_IME("input_ime"),
    VIDEO_PLAYBACK("video_playback");

    companion object {
        fun fromName(name: String): BenchScene? = entries.firstOrNull { it.sceneName == name }
    }
}

/// Collected metrics for one scene run (bench.zig Metrics).
data class Metrics(
    val scene: BenchScene,
    val fps: Double,
    val frameTimeAvgMs: Double,
    val frameTimeP50Ms: Double,
    val frameTimeP99Ms: Double,
    val drawCallsPerFrame: Long,
    val rssMb: Double,
    val ttffMs: Double,
    val framesRendered: Long,
)

/// A WindowInfo for the headless scene (the published WindowInfoImpl is
/// internal; the WindowInfo interface is public).
private class BenchWindowInfo(override val containerSize: IntSize) : WindowInfo {
    override val isWindowFocused: Boolean = true
}

/// One scene's headless run: surface + ComposeScene + the unpaced frame loop.
class Harness(private val scene: BenchScene) {
    private var surface: Surface = Surface.makeRasterN32Premul(WIDTH, HEIGHT)
    private lateinit var composeScene: ComposeScene
    private val state = SceneState(scene)

    /// Run the scene headlessly and collect its metrics (bench.zig runScene).
    fun run(): Metrics {
        val runStartNs = System.nanoTime()
        val windowInfo = BenchWindowInfo(IntSize(WIDTH, HEIGHT))
        val platformContext = object : PlatformContext by PlatformContext.Empty {
            override val windowInfo: WindowInfo get() = windowInfo
        }
        composeScene = CanvasLayersComposeScene(
            density = Density(1f),
            layoutDirection = LayoutDirection.Ltr,
            size = IntSize(WIDTH, HEIGHT),
            coroutineContext = Dispatchers.Unconfined,
            platformContext = platformContext,
            invalidate = {}, // the harness renders every frame itself; nothing to schedule
        )
        composeScene.setContent { state.Content() }

        val frameTimesMs = DoubleArray(MEASURED_FRAMES)
        var ttffMs = 0.0
        for (i in 0 until TOTAL_FRAMES) {
            val t0 = System.nanoTime()
            state.tick(i.toLong(), this) // scene logic (scroll / anim / ime / video / resize)
            surface.canvas.clear(BG_ARGB) // Klaxon's paint(root, BG) clear
            // recomposition + measure/layout + draw, synchronously
            composeScene.render(surface.canvas.asComposeCanvas(), System.nanoTime())
            val t1 = System.nanoTime()
            if (i == 0) ttffMs = (t1 - runStartNs) / 1e6
            if (i >= WARMUP_FRAMES) frameTimesMs[i - WARMUP_FRAMES] = (t1 - t0) / 1e6
        }

        val drawCalls = countLayoutNodes(composeScene)
        val rssMb = readRssMb()
        composeScene.close()
        surface.close()

        val avg = frameTimesMs.average()
        val sorted = frameTimesMs.sortedArray()
        // Nearest-rank percentile, exactly like bench.zig's `percentile`.
        fun percentile(p: Int) = sorted[min((MEASURED_FRAMES * p) / 100, MEASURED_FRAMES - 1)]
        return Metrics(
            scene = scene,
            fps = if (avg > 0) 1000.0 / avg else 0.0,
            frameTimeAvgMs = avg,
            frameTimeP50Ms = percentile(50),
            frameTimeP99Ms = percentile(99),
            drawCallsPerFrame = drawCalls,
            rssMb = rssMb,
            ttffMs = ttffMs,
            framesRendered = TOTAL_FRAMES.toLong(),
        )
    }

    /// resize scene: cycle the viewport (Klaxon's kx_resize + full relayout).
    fun resizeScene(width: Int, height: Int) {
        composeScene.size = IntSize(width, height)
        surface.close()
        surface = Surface.makeRasterN32Premul(width, height)
    }
}

// --- draw_calls_per_frame: placed layout nodes in the scene's LayoutNode tree ---

// LayoutNode / Owner are internal in the published Compose desktop artifacts,
// so the tree walk is pure reflection: one field read bridges from the scene to
// its RootNodeOwner (`mainOwner`), then getters walk down (Owner.root ->
// LayoutNode.getChildren() / LayoutNode.isPlaced()). The children accessor is
// located by name (`getChildren`, possibly internal-name-mangled to
// `getChildren$<module>`) — the property has no backing field to read.
private val layoutNodeClass = Class.forName("androidx.compose.ui.node.LayoutNode")
private val layoutNodeChildrenGetter = layoutNodeClass.declaredMethods.first {
    it.parameterCount == 0 && (it.name == "getChildren" || it.name.startsWith("getChildren$"))
}.apply { isAccessible = true }
private val layoutNodeIsPlacedMethod = layoutNodeClass.getMethod("isPlaced")

/// The number of placed layout nodes under the scene's root (Klaxon's
/// countPaintNodes analog: visible painted nodes, counted after the final
/// frame).
fun countLayoutNodes(scene: ComposeScene): Long {
    return try {
        val mainOwnerField =
            scene.javaClass.getDeclaredField("mainOwner").apply { isAccessible = true }
        val rootNodeOwner = mainOwnerField.get(scene)
        // RootNodeOwner is an internal class and its OwnerImpl a private inner
        // class — the getters need setAccessible even though they are public.
        val owner = rootNodeOwner.javaClass.getMethod("getOwner")
            .apply { isAccessible = true }.invoke(rootNodeOwner)
        val root = owner.javaClass.getMethod("getRoot")
            .apply { isAccessible = true }.invoke(owner)
        countPlaced(root)
    } catch (e: Exception) {
        System.err.println("klaxon bench compose: layout-node counting failed: $e")
        0
    }
}

private fun countPlaced(node: Any): Long {
    if (layoutNodeIsPlacedMethod.invoke(node) as Boolean != true) return 0
    var count = 1L
    @Suppress("UNCHECKED_CAST")
    val children = layoutNodeChildrenGetter.invoke(node) as Collection<Any>
    for (child in children) count += countPlaced(child)
    return count
}

// --- rss_mb: process RSS via ps (macOS: KiB) ---

private fun readRssMb(): Double {
    return try {
        val pid = ProcessHandle.current().pid()
        val ps = ProcessBuilder("ps", "-o", "rss=", "-p", pid.toString())
            .redirectErrorStream(true).start()
        val out = ps.inputStream.readBytes().toString(Charsets.UTF_8).trim()
        ps.waitFor()
        out.toDoubleOrNull()?.let { it / 1024.0 } ?: 0.0
    } catch (e: Exception) {
        0.0
    }
}

// --- the JSON report (bench_main.zig formatReport — same shape + formatting) ---

private fun fmt1(v: Double) = String.format(Locale.ROOT, "%.1f", v)

private fun formatReport(results: List<Metrics>, binarySizeBytes: Long, timestamp: String): String {
    val sb = StringBuilder()
    sb.append("{\n  \"scenes\": [\n")
    results.forEachIndexed { i, m ->
        if (i > 0) sb.append(",\n")
        sb.append("    {\n")
        sb.append("      \"name\": \"${m.scene.sceneName}\",\n")
        sb.append("      \"fps\": ${fmt1(m.fps)},\n")
        sb.append("      \"frame_time_avg_ms\": ${fmt1(m.frameTimeAvgMs)},\n")
        sb.append("      \"frame_time_p50_ms\": ${fmt1(m.frameTimeP50Ms)},\n")
        sb.append("      \"frame_time_p99_ms\": ${fmt1(m.frameTimeP99Ms)},\n")
        sb.append("      \"draw_calls_per_frame\": ${m.drawCallsPerFrame},\n")
        sb.append("      \"rss_mb\": ${fmt1(m.rssMb)},\n")
        sb.append("      \"ttff_ms\": ${fmt1(m.ttffMs)},\n")
        sb.append("      \"frames_rendered\": ${m.framesRendered}\n")
        sb.append("    }")
    }
    sb.append("\n  ],\n")
    sb.append("  \"binary_size_bytes\": $binarySizeBytes,\n")
    sb.append("  \"timestamp\": \"$timestamp\"\n")
    sb.append("}\n")
    return sb.toString()
}

/// Size of the runnable fat jar in bytes (KLAXON_BENCH_BIN, set by run.sh;
/// falls back to build/libs/*-all.jar under the working directory).
private fun binarySizeBytes(): Long {
    val fromEnv = System.getenv("KLAXON_BENCH_BIN")
    val file = if (!fromEnv.isNullOrBlank()) {
        File(fromEnv)
    } else {
        File("build/libs").listFiles()?.firstOrNull { it.isFile && it.name.endsWith("-all.jar") }
    }
    return file?.takeIf { it.isFile }?.length() ?: 0L
}

private fun isoTimestamp(now: Instant) =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC).format(now)

private fun fileTimestamp(now: Instant) =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH-mm-ss'Z'").withZone(ZoneOffset.UTC).format(now)

/// Write the report to bench/results/compose/<ISO8601-timestamp>.json
/// (KLAXON_BENCH_OUT_DIR, set by run.sh; falls back to a CWD-relative path).
private fun writeReportFile(json: String, now: Instant) {
    val dir = System.getenv("KLAXON_BENCH_OUT_DIR") ?: "bench/results/compose"
    val file = File(dir, fileTimestamp(now) + ".json")
    file.parentFile?.mkdirs()
    file.writeText(json)
    System.err.println("klaxon bench compose: report written to ${file.absolutePath}")
}

// --- entry point ---

fun main(args: Array<String>) {
    if (args.contains("--probe")) {
        runProbe()
        return
    }
    val sceneArg = args.firstOrNull { !it.startsWith("--") }
    val scenes: List<BenchScene> = when (sceneArg) {
        null -> BenchScene.entries.toList()
        else -> listOf(BenchScene.fromName(sceneArg) ?: run {
            System.err.println(
                "klaxon bench compose: unknown scene '$sceneArg' — valid scenes: " +
                    BenchScene.entries.joinToString(" ") { it.sceneName }
            )
            exitProcess(2)
        })
    }
    val results = scenes.mapIndexed { idx, scene ->
        System.err.println("klaxon bench compose: ${scene.sceneName} (${idx + 1}/${scenes.size})...")
        Harness(scene).run()
    }
    val now = Instant.now()
    val json = formatReport(results, binarySizeBytes(), isoTimestamp(now))
    System.out.print(json)
    System.out.flush()
    writeReportFile(json, now)
    exitProcess(0)
}

// --- probe: headless render sanity checks (dev-only; `run.sh` never passes it) ---

private fun runProbe() {
    System.err.println("klaxon bench compose: probe: headless render sanity checks")
    var failures = 0
    fun check(name: String, ok: Boolean, detail: String = "") {
        System.err.println(
            "klaxon bench compose: probe: $name: ${if (ok) "OK" else "FAIL"}" +
                if (detail.isNotEmpty()) " ($detail)" else ""
        )
        if (!ok) failures++
    }

    val surface = Surface.makeRasterN32Premul(WIDTH, HEIGHT)

    // 1. a scene renders ink.
    val scene1 = CanvasLayersComposeScene(
        density = Density(1f), size = IntSize(WIDTH, HEIGHT), coroutineContext = Dispatchers.Unconfined
    )
    scene1.setContent {
        Box(Modifier.fillMaxSize().background(Color(0xFF14141C))) {
            Box(Modifier.size(100.dp).align(Alignment.Center).background(Color(0xFFE91E63)))
        }
    }
    surface.canvas.clear(BG_ARGB)
    scene1.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    val ink = countInk(surface)
    check("scene renders ink", ink > 1000, "ink pixels=$ink")

    // 2. a state change recomposes (pixels change between frames).
    var bg by mutableStateOf(Color(0xFF14141C))
    scene1.setContent { Box(Modifier.fillMaxSize().background(bg)) }
    scene1.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    val hashBefore = surfaceHash(surface)
    bg = Color(0xFF101426)
    scene1.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    check("state change recomposes", surfaceHash(surface) != hashBefore)
    scene1.close()

    // 3. LazyColumn + runBlocking { scrollToItem } works (no hang, applies).
    val scene2 = CanvasLayersComposeScene(
        density = Density(1f), size = IntSize(WIDTH, HEIGHT), coroutineContext = Dispatchers.Unconfined
    )
    var ls: androidx.compose.foundation.lazy.LazyListState? = null
    scene2.setContent {
        ls = rememberLazyListState()
        LazyColumn(state = ls!!, modifier = Modifier.fillMaxSize()) {
            items(1000) { Text("row $it", color = Color.White, fontSize = 14.sp) }
        }
    }
    scene2.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    val scrollDone = CompletableFuture<Boolean>()
    val worker = Thread {
        try {
            runBlocking { ls!!.scrollToItem(500, 0) }
            scrollDone.complete(true)
        } catch (e: Throwable) {
            scrollDone.complete(false)
        }
    }
    worker.start()
    worker.join(5000)
    check("scrollToItem does not hang", scrollDone.isDone && scrollDone.get() == true)
    val hashBeforeScroll = surfaceHash(surface)
    scene2.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    check(
        "scroll position applied",
        ls!!.firstVisibleItemIndex == 500,
        "firstVisibleItemIndex=${ls!!.firstVisibleItemIndex}"
    )
    check("scroll changes pixels", surfaceHash(surface) != hashBeforeScroll)
    scene2.close()

    // 4. CJK + emoji text renders ink (Skiko/CoreText falls back to PingFang /
    //    Apple Color Emoji on macOS — see README).
    val scene3 = CanvasLayersComposeScene(
        density = Density(1f), size = IntSize(WIDTH, HEIGHT), coroutineContext = Dispatchers.Unconfined
    )
    scene3.setContent {
        Box(Modifier.fillMaxSize().background(Color(0xFF14141C))) {
            Text(
                "你好，世界！こんにちは、世界！안녕하세요, 세계! 🌍🎉",
                color = Color.White, fontSize = 22.sp,
                modifier = Modifier.align(Alignment.Center)
            )
        }
    }
    surface.canvas.clear(BG_ARGB)
    scene3.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    val cjkInk = countInk(surface)
    check("CJK + emoji text renders ink", cjkInk > 1000, "ink pixels=$cjkInk")
    scene3.close()

    // 5. layout-node counting works.
    val scene4 = CanvasLayersComposeScene(
        density = Density(1f), size = IntSize(WIDTH, HEIGHT), coroutineContext = Dispatchers.Unconfined
    )
    scene4.setContent {
        Box(Modifier.fillMaxSize()) { Text("hi", color = Color.White) }
    }
    scene4.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    val nodes = countLayoutNodes(scene4)
    check("layout-node counting", nodes in 2..50, "placed layout nodes=$nodes")
    scene4.close()

    surface.close()
    System.err.println(
        "klaxon bench compose: probe: " +
            if (failures == 0) "all checks passed" else "$failures check(s) FAILED"
    )
    exitProcess(if (failures == 0) 0 else 1)
}

private fun surfaceHash(surface: Surface): Long {
    Bitmap().use { bitmap ->
        bitmap.allocN32Pixels(WIDTH, HEIGHT)
        surface.readPixels(bitmap, 0, 0)
        val bytes = bitmap.readPixels() ?: return 0L
        var h = 1125899906842597L
        for (b in bytes) h = h * 31 + b.toLong()
        return h
    }
}

private fun countInk(surface: Surface): Int {
    Bitmap().use { bitmap ->
        bitmap.allocN32Pixels(WIDTH, HEIGHT)
        surface.readPixels(bitmap, 0, 0)
        val bytes = bitmap.readPixels() ?: return 0
        var ink = 0
        var i = 0
        while (i + 3 < bytes.size) {
            // N32 memory order on macOS is B,G,R,A — any channel differing
            // from the BG clear (#14141C -> B=0x1C, G=0x14, R=0x14) is ink.
            if (bytes[i] != 0x1C.toByte() || bytes[i + 1] != 0x14.toByte() || bytes[i + 2] != 0x14.toByte()) ink++
            i += 4
        }
        return ink
    }
}
