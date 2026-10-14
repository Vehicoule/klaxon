// Bench.kt — the Compose Multiplatform comparison benchmark runner (roadmap 4c.4/4c.6).
//
// A JVM port of Klaxon's own benchmark (src/bench.zig + src/bench_main.zig): it
// renders the same scenes at the same harness settings (640x480, 10 warmup +
// 120 measured frames, unpaced — the docs/specs/bench-scenes.md schema-v2
// contract) and emits the same JSON report, so Klaxon (Zig + Skia + SDL3) and
// Compose Multiplatform can be compared head-to-head.
//
// Headless by construction, like Klaxon's bench: no window, no GPU, no vsync.
// The harness drives androidx.compose.ui.scene.CanvasLayersComposeScene (the
// scene API Compose itself uses for offscreen rendering) into a CPU raster
// Skiko surface and calls scene.render(...) once per frame in an unpaced loop.
// Per BaseComposeScene.render, one call runs: flush effects -> recomposition ->
// frame clock -> measure/layout -> draw — the Compose analog of Klaxon's
// tick + layout + paint, all synchronously on the calling thread.
//
// Metric definitions mirror bench.zig (+ the schema-v2 additions):
//   - fps: 1000 / frame_time_avg_ms (the loop is unpaced).
//   - frame_time_*: per-frame wall time of tick + recomposition + layout + draw,
//     measured frames only (warmup frames are rendered but not counted).
//   - frame_time_p999_ms: nearest-rank 99.9th percentile (schema v2).
//   - jank_frames / jank_pct: frames with frame_ms > 16.67 (60 Hz budget,
//     Macrobenchmark/JankStats convention — schema v2).
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
//   - frames_rendered: total rendered frames — 130 for a normal scene
//     (10 warmup + 120 measured), 71 for a list_ops scene (10 warmup + 1 op
//     frame + 60 measured), 270 for a ramp scene (9 steps x (10+20)).
//   - extra: per-scene fields (op_ms, ramp[]/n_max_60fps, latency_*,
//     nodes_per_frame, teardown_ms/resume_ms) — see the families in Scenes*.kt.
@file:OptIn(InternalComposeUiApi::class)

package bench.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asComposeCanvas
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.PlatformContext
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.scene.CanvasLayersComposeScene
import androidx.compose.ui.scene.ComposeScene
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsOwner
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.Surface
import org.jetbrains.skiko.GraphicsApi
import org.jetbrains.skiko.SkiaLayer
import org.jetbrains.skiko.SkiaLayerProperties
import org.jetbrains.skiko.SkikoRenderDelegate
import java.awt.Dimension
import java.io.File
import javax.swing.JFrame
import javax.swing.SwingUtilities
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.CompletableFuture
import kotlin.math.min
import kotlin.system.exitProcess

/** Harness settings — the docs/specs/bench-scenes.md schema-v2 contract. */
const val WIDTH = 640
const val HEIGHT = 480
const val WARMUP_FRAMES = 10
const val MEASURED_FRAMES = 120

/** 60 Hz frame budget for the schema-v2 jank metrics (Macrobenchmark/JankStats). */
const val JANK_BUDGET_MS = 16.67

/** list_ops: frame-timing metrics are collected over 60 frames after the op. */
const val LIST_OP_MEASURED_FRAMES = 60

/** ramp (MotionMark): the stepped item counts, 10 warmup + 20 measured per step. */
val RAMP_STEPS = listOf(10, 25, 50, 100, 200, 400, 800, 1600, 3200)
const val RAMP_WARMUP_FRAMES = 10
const val RAMP_MEASURED_FRAMES = 20

/** input_latency: the synthetic pointer event is injected at this frame index. */
const val LATENCY_INJECT_FRAME = 40L

/** app_switch: one pause->resume cycle every 60 frames. */
const val APP_SWITCH_PERIOD = 60L

/** bench.zig BG (0x14141CFF, RRGGBBAA) as a Skia ARGB clear color. */
private val BG_ARGB = 0xFF14141C.toInt()

/** Tier-2 windowed mode (run.sh --windowed / KLAXON_BENCH_WINDOWED=1): the
 *  same scenes render into a REAL JFrame + org.jetbrains.skiko.SkiaLayer on
 *  Metal instead of the headless raster surface. Each frame is driven by
 *  SkiaLayer.paint() — a synchronous onRender + flush + present on the caller
 *  thread — timed wall-to-wall. Skiko vsync is disabled so the present call
 *  does not block on the display clock: the contract is work-per-frame, the
 *  same span Klaxon (last_frame_wait_ns subtracted), the Qt RHI runner
 *  (beforeRenderPassRecording -> afterRendering) and Flutter's FrameTiming
 *  work spans measure.
 *  The report's "backend" field records the resolved path. */
private val WINDOWED = System.getenv("KLAXON_BENCH_WINDOWED") == "1"

/// How a scene's frames are scheduled (docs/specs/bench-scenes.md).
enum class SceneKind {
    /** 10 warmup + 120 measured frames (the default contract). */
    NORMAL,

    /** 10 warmup frames, then the timed op frame (extra.op_ms), then 60 measured frames. */
    LIST_OP,

    /** RAMP_STEPS item counts; 10 warmup + 20 measured frames per step. */
    RAMP,
}

/// The canonical scenes (bench.zig BenchScene + the docs/specs/bench-scenes.md
/// schema-v2 catalogue: 6 list_ops + 4 ramp + 10 stress + 4 system).
enum class BenchScene(val sceneName: String, val kind: SceneKind = SceneKind.NORMAL) {
    // the 9 original scenes (bench.zig)
    HELLO("hello"),
    SCROLL_10K("scroll_10k"),
    TEXT_CJK("text_cjk"),
    GLASS_BLUR("glass_blur"),
    ANIM_100("anim_100"),
    GALLERY("gallery"),
    RESIZE("resize"),
    INPUT_IME("input_ime"),
    VIDEO_PLAYBACK("video_playback"),

    // Family A — list_ops (krausest js-framework-benchmark, native adaptation)
    LIST_CREATE_1K("list_create_1k", SceneKind.LIST_OP),
    LIST_REPLACE_1K("list_replace_1k", SceneKind.LIST_OP),
    LIST_UPDATE_10TH("list_update_10th", SceneKind.LIST_OP),
    LIST_SWAP_ROWS("list_swap_rows", SceneKind.LIST_OP),
    LIST_REMOVE_ROW("list_remove_row", SceneKind.LIST_OP),
    LIST_CLEAR_1K("list_clear_1k", SceneKind.LIST_OP),

    // Family B — ramp (MotionMark methodology)
    SHAPES_RAMP("shapes_ramp", SceneKind.RAMP),
    PATHS_RAMP("paths_ramp", SceneKind.RAMP),
    TEXT_RAMP("text_ramp", SceneKind.RAMP),
    IMAGES_RAMP("images_ramp", SceneKind.RAMP),

    // Family C — stress (known-divergence scenarios)
    OVERDRAW_STACK("overdraw_stack"),
    ELEVATION_GRID("elevation_grid"),
    RELAYOUT_STORM("relayout_storm"),
    MOUNT_CHURN("mount_churn"),
    SCROLL_ANIM("scroll_anim"),
    TEXT_RICH("text_rich"),
    CHART_LIVE("chart_live"),
    CLIP_PATH("clip_path"),
    THEME_SWITCH("theme_switch"),
    BACKDROP_SCROLL("backdrop_scroll"),

    // Family D — system (non-paint paths)
    INPUT_LATENCY("input_latency"),
    POINTER_STORM("pointer_storm"),
    SEMANTICS_BUILD("semantics_build"),
    APP_SWITCH("app_switch");

    companion object {
        fun fromName(name: String): BenchScene? = entries.firstOrNull { it.sceneName == name }
    }
}

/// Collected metrics for one scene run (bench.zig Metrics + schema v2). `extra`
/// holds scene-specific fields as raw JSON fragments (key -> already-encoded
/// JSON value), emitted under `"extra": { ... }`.
data class Metrics(
    val scene: BenchScene,
    val fps: Double,
    val frameTimeAvgMs: Double,
    val frameTimeP50Ms: Double,
    val frameTimeP99Ms: Double,
    val frameTimeP999Ms: Double,
    val jankFrames: Long,
    val jankPct: Double,
    val drawCallsPerFrame: Long,
    val rssMb: Double,
    val ttffMs: Double,
    val framesRendered: Long,
    val extra: List<Pair<String, String>>,
)

/// A WindowInfo for the headless scene (the published WindowInfoImpl is
/// internal; the WindowInfo interface is public).
private class BenchWindowInfo(override val containerSize: IntSize) : WindowInfo {
    override val isWindowFocused: Boolean = true
}

/// One scene's headless run: surface + ComposeScene + the unpaced frame loop.
class Harness(private val scene: BenchScene) {
    // The run clock starts BEFORE the scene's model init (field order =
    // init order) — Klaxon's ttff covers scene build, and list_ops /
    // mount_churn populate hundreds of rows in SceneState's init.
    private val runStartNs = System.nanoTime()
    private var surface: Surface? = if (WINDOWED) null else Surface.makeRasterN32Premul(WIDTH, HEIGHT)
    private lateinit var composeScene: ComposeScene
    private lateinit var platformContext: PlatformContext
    private val state = SceneState(scene)

    // Windowed tier-2: the real JFrame + SkiaLayer the scene renders into
    // (null headless). contentScale = the display's pixel scale (2.0 on
    // Retina — the scene's logical size stays 640x480 dp like every runner).
    private var jframe: JFrame? = null
    private var layer: SkiaLayer? = null
    private var contentScale = 1f
    // The delegate's onRender span (BG clear + ComposeScene.render — the
    // CPU-side build/layout/draw work, the same span Klaxon's paint()
    // measures). paint() wraps it in Skiko machinery (drawable acquire +
    // flush + present) that stays paced by the WindowServer commit cadence
    // (~8.3 ms on this 120 Hz panel) even with vsync off — that machinery
    // is wall overhead, not frame work, and is subtracted like Klaxon's
    // last_frame_wait_ns.
    private var lastOnRenderNs = 0L
    private var lastPaintMachineryNs = 0L

    private var ttffMs = 0.0
    private var framesRendered = 0L

    // input_latency bookkeeping: frames rendered from the pointer injection
    // until the frame that paints the visual response.
    private var injectT0Ns = 0L
    private var awaitingResponse = false
    private var framesSinceInject = 0

    /// Run the scene headlessly and collect its metrics (bench.zig runScene).
    fun run(): Metrics {
        val windowInfo = BenchWindowInfo(IntSize(WIDTH, HEIGHT))
        platformContext = object : PlatformContext by PlatformContext.Empty {
            override val windowInfo: WindowInfo get() = windowInfo
        }
        if (WINDOWED) createWindow()
        composeScene = buildScene()
        composeScene.setContent { state.Content() }
        if (WINDOWED) {
            // The delegate owns the BG clear + scene render; Skiko's flush +
            // present run inside the same paint() call (vsync disabled).
            layer!!.renderDelegate = object : SkikoRenderDelegate {
                override fun onRender(
                    canvas: org.jetbrains.skia.Canvas,
                    width: Int,
                    height: Int,
                    nanoTime: Long,
                ) {
                    val rt0 = System.nanoTime()
                    canvas.clear(BG_ARGB)
                    composeScene.render(canvas.asComposeCanvas(), nanoTime)
                    lastOnRenderNs = System.nanoTime() - rt0
                }
            }
        }

        val frameTimesMs = when (scene.kind) {
            SceneKind.RAMP -> runRamp(runStartNs)
            else -> runStandard(runStartNs)
        }

        val drawCalls = countLayoutNodes(composeScene)
        val rssMb = readRssMb()
        composeScene.close()
        surface?.close()
        if (WINDOWED) {
            layer?.detach()
            jframe?.dispose()
            jframe = null
            layer = null
        }
        state.finalizeExtras()

        val avg = frameTimesMs.average()
        val sorted = frameTimesMs.sortedArray()
        // Nearest-rank percentile, exactly like bench.zig's `percentile`
        // (p999 = num/den fraction for the 99.9th percentile).
        fun percentile(num: Int, den: Int) =
            sorted[min((frameTimesMs.size.toLong() * num / den).toInt(), frameTimesMs.size - 1)]
        val jank = frameTimesMs.count { it > JANK_BUDGET_MS }
        return Metrics(
            scene = scene,
            fps = if (avg > 0) 1000.0 / avg else 0.0,
            frameTimeAvgMs = avg,
            frameTimeP50Ms = percentile(50, 100),
            frameTimeP99Ms = percentile(99, 100),
            frameTimeP999Ms = percentile(999, 1000),
            jankFrames = jank.toLong(),
            jankPct = 100.0 * jank / frameTimesMs.size,
            drawCallsPerFrame = drawCalls,
            rssMb = rssMb,
            ttffMs = ttffMs,
            framesRendered = framesRendered,
            extra = state.extras.toList(),
        )
    }

    /// The windowed JFrame + SkiaLayer (Metal, vsync off — see WINDOWED).
    /// Runs on the EDT like the rest of the windowed harness.
    private fun createWindow() {
        val frame = JFrame("klaxon-bench-compose")
        frame.defaultCloseOperation = JFrame.DO_NOTHING_ON_CLOSE
        val skiaLayer = SkiaLayer(
            properties = SkiaLayerProperties(
                isVsyncEnabled = false,
                // TRIPLE: with DOUBLE the CAMetalLayer drawable pool is
                // exhausted after two in-flight presents, so nextDrawable
                // inside paint() blocks on the OS compositor's 120 Hz
                // release cadence — an ~8.3 ms floor unrelated to scene
                // work. A deeper pool lets presents overlap so the acquire
                // returns immediately on an unpaced run.
                frameBuffering = org.jetbrains.skiko.FrameBuffering.TRIPLE,
                renderApi = GraphicsApi.METAL,
            ),
        )
        skiaLayer.preferredSize = Dimension(WIDTH, HEIGHT)
        frame.contentPane.add(skiaLayer)
        frame.pack()
        frame.isVisible = true
        contentScale = skiaLayer.contentScale
        jframe = frame
        layer = skiaLayer
        System.err.println(
            "klaxon bench compose: windowed — ${skiaLayer.renderApi} layer," +
                " contentScale=$contentScale, vsync off"
        )
    }

    /// The headless scene (the same construction for the first composition and
    /// every app_switch resume).
    private fun buildScene() = CanvasLayersComposeScene(
        density = Density(contentScale),
        layoutDirection = LayoutDirection.Ltr,
        size = IntSize((WIDTH * contentScale).toInt(), (HEIGHT * contentScale).toInt()),
        coroutineContext = Dispatchers.Unconfined,
        platformContext = platformContext,
        invalidate = {}, // the harness renders every frame itself; nothing to schedule
    )

    /// One frame: scene tick -> optional pointer injection -> BG clear ->
    /// recomposition + layout + draw -> post-render work. Returns the frame's
    /// wall time in ms (the analog of bench.zig's timed region).
    private fun renderFrame(frame: Long, runStartNs: Long): Double {
        val t0 = System.nanoTime()
        state.tick(frame, this) // scene logic (scroll / anim / ops / input / switch)
        if (state.consumePointerInjection()) {
            injectT0Ns = System.nanoTime()
            awaitingResponse = true
            framesSinceInject = 0
            composeScene.sendPointerEvent(
                PointerEventType.Press,
                Offset(WIDTH / 2f * contentScale, HEIGHT / 2f * contentScale),
            )
        }
        // A response paints on the first render that runs with the response
        // state already set — check BEFORE this render (a response delivered
        // during a render is painted by the next one).
        val responseWasSet = awaitingResponse && state.responseArrived
        drawFrame() // BG clear + recomposition + measure/layout + draw, synchronously
        state.postRender(frame, this) // timed post-render work (semantics walk)
        val t1 = System.nanoTime()
        // tWork: end instant in "work time" (Skiko's paced acquire/flush/
        // present machinery subtracted — see lastPaintMachineryNs). ttff
        // stays wall-to-wall like Klaxon's ttff_ms.
        val tWork = t1 - lastPaintMachineryNs
        if (framesRendered == 0L) ttffMs = (t1 - runStartNs) / 1e6
        framesRendered++
        if (awaitingResponse) {
            framesSinceInject++
            if (responseWasSet) {
                state.putExtra("latency_frames", framesSinceInject.toString())
                state.putExtra("latency_ms", fmt1((tWork - injectT0Ns) / 1e6))
                awaitingResponse = false
            }
        }
        return (tWork - t0) / 1e6
    }

    /// One rendered frame. Headless: clear the raster surface + scene.render
    /// (recomposition + measure/layout + draw, synchronously). Windowed: a
    /// synchronous SkiaLayer.paint() — the render delegate clears + calls
    /// scene.render, then Skiko flushes and presents (vsync off, so the
    /// present call returns without waiting) — the timed span covers the
    /// same work Klaxon measures inside begin->end frame.
    private fun drawFrame() {
        val l = layer
        if (l != null) {
            val p0 = System.nanoTime()
            l.paint(l.graphics)
            val p1 = System.nanoTime()
            // paint() wall = acquire + onRender + flush + present. The
            // delegate records its own span; the rest is Skiko's paced
            // machinery, excluded from the frame's work time.
            lastPaintMachineryNs = (p1 - p0) - lastOnRenderNs
        } else {
            val s = surface!!
            s.canvas.clear(BG_ARGB) // Klaxon's paint(root, BG) clear
            composeScene.render(s.canvas.asComposeCanvas(), System.nanoTime())
        }
    }

    /// NORMAL + LIST_OP: 10 warmup frames, then (list_ops only) one timed op
    /// frame captured as extra.op_ms, then the measured frames.
    private fun runStandard(runStartNs: Long): DoubleArray {
        val isListOp = scene.kind == SceneKind.LIST_OP
        val measuredCount = if (isListOp) LIST_OP_MEASURED_FRAMES else MEASURED_FRAMES
        val frameTimesMs = DoubleArray(measuredCount)
        val total = WARMUP_FRAMES + (if (isListOp) 1 else 0) + measuredCount
        var measured = 0
        for (i in 0 until total) {
            val dt = renderFrame(i.toLong(), runStartNs)
            if (isListOp && i == WARMUP_FRAMES) {
                // The op frame: model mutation + one full render pass = op_ms.
                state.putExtra("op_ms", fmt1(dt))
            } else if (i >= WARMUP_FRAMES) {
                frameTimesMs[measured++] = dt
            }
        }
        return frameTimesMs
    }

    /// RAMP: stepped item counts (MotionMark). Per step: set N, 10 warmup
    /// frames, 20 measured frames; per-step p50 goes to extra.ramp[] and the
    /// largest step at 60 fps to extra.n_max_60fps. The returned pool holds all
    /// 9 x 20 measured frames for the top-level frame metrics.
    private fun runRamp(runStartNs: Long): DoubleArray {
        val pooled = DoubleArray(RAMP_STEPS.size * RAMP_MEASURED_FRAMES)
        val ramp = ArrayList<Pair<Int, Double>>(RAMP_STEPS.size)
        var idx = 0
        var frame = 0L // one continuous animation clock across steps
        for (n in RAMP_STEPS) {
            state.rampItemCount.intValue = n
            repeat(RAMP_WARMUP_FRAMES) { renderFrame(frame++, runStartNs) }
            val stepTimes = DoubleArray(RAMP_MEASURED_FRAMES)
            for (m in 0 until RAMP_MEASURED_FRAMES) {
                val dt = renderFrame(frame++, runStartNs)
                stepTimes[m] = dt
                pooled[idx++] = dt
            }
            val sorted = stepTimes.sortedArray()
            ramp += n to sorted[min((RAMP_MEASURED_FRAMES * 50) / 100, RAMP_MEASURED_FRAMES - 1)]
        }
        state.putExtra(
            "ramp",
            ramp.joinToString(", ", "[", "]") { (n, p50) -> "{\"n\": $n, \"p50_ms\": ${fmt1(p50)}}" },
        )
        state.putExtra("n_max_60fps", (ramp.lastOrNull { it.second <= JANK_BUDGET_MS }?.first ?: 0).toString())
        return pooled
    }

    /// resize scene: cycle the viewport (Klaxon's kx_resize + full relayout).
    fun resizeScene(width: Int, height: Int) {
        if (WINDOWED) {
            // The real window + the scene's pixel extent follow the logical
            // size (Klaxon resizes its real window/surface the same way).
            composeScene.size =
                IntSize((width * contentScale).toInt(), (height * contentScale).toInt())
            layer?.preferredSize = Dimension(width, height)
            jframe?.pack()
        } else {
            composeScene.size = IntSize(width, height)
            surface?.close()
            surface = Surface.makeRasterN32Premul(width, height)
        }
    }

    /// pointer_storm: one synthetic hit-test query (a move event does a full
    /// hit-test dispatch; no paint change — the tree has no move handlers that
    /// mutate state).
    fun sendPointerMove(x: Float, y: Float) {
        composeScene.sendPointerEvent(
            PointerEventType.Move,
            Offset(x * contentScale, y * contentScale),
        )
    }

    /// app_switch: the pause->resume cycle. Headless Compose has no lifecycle,
    /// so the closest idiom is dispose + recreate: teardown_ms = close() (the
    /// composition is disposed), resume_ms = new scene + setContent through the
    /// END of the first completed frame (resume-to-frame, per the spec).
    fun pauseResumeCycle() {
        val t0 = System.nanoTime()
        composeScene.close()
        val teardownMs = (System.nanoTime() - t0) / 1e6

        val t1 = System.nanoTime()
        composeScene = buildScene()
        composeScene.setContent { state.Content() }
        drawFrame()
        // The resume render is a real drawn frame — count it so
        // frames_rendered reflects actual work (130 ticks → 132 draws
        // for app_switch, which pauses/resumes at frames 60 and 120).
        framesRendered++
        val resumeMs = (System.nanoTime() - t1) / 1e6

        state.recordSwitchCycle(teardownMs, resumeMs)
    }

    /// semantics_build: the number of nodes in the merged a11y semantics tree
    /// (SemanticsOwner is reached through the same reflective bridge as
    /// countLayoutNodes — ComposeScene exposes no semantics accessor in CMP
    /// 1.8.2; SemanticsOwner/SemanticsNode themselves are public API).
    fun countSemanticsNodes(): Long {
        return try {
            val owner = sceneOwner(composeScene) ?: return 0
            val ownerSemantics = owner.javaClass.getMethod("getSemanticsOwner")
                .apply { isAccessible = true }.invoke(owner) as SemanticsOwner
            countSemantics(ownerSemantics.rootSemanticsNode)
        } catch (e: Exception) {
            System.err.println("klaxon bench compose: semantics walk failed: $e")
            0
        }
    }

    private fun countSemantics(node: SemanticsNode): Long {
        var count = 1L
        for (child in node.children) count += countSemantics(child)
        return count
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

/// The scene's Owner, reached through its RootNodeOwner (`mainOwner` field ->
/// `getOwner()`). Shared by the layout-node and semantics walks. RootNodeOwner
/// is an internal class and its OwnerImpl a private inner class — the getters
/// need setAccessible even though they are public.
private fun sceneOwner(scene: ComposeScene): Any? {
    return try {
        val mainOwnerField =
            scene.javaClass.getDeclaredField("mainOwner").apply { isAccessible = true }
        val rootNodeOwner = mainOwnerField.get(scene)
        rootNodeOwner.javaClass.getMethod("getOwner")
            .apply { isAccessible = true }.invoke(rootNodeOwner)
    } catch (e: Exception) {
        System.err.println("klaxon bench compose: owner lookup failed: $e")
        null
    }
}

/// The number of placed layout nodes under the scene's root (Klaxon's
/// countPaintNodes analog: visible painted nodes, counted after the final
/// frame).
fun countLayoutNodes(scene: ComposeScene): Long {
    return try {
        val owner = sceneOwner(scene) ?: return 0
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

internal fun fmt1(v: Double) = String.format(Locale.ROOT, "%.1f", v)
internal fun fmt3(v: Double) = String.format(Locale.ROOT, "%.3f", v)

private fun formatReport(
    results: List<Metrics>,
    binarySizeBytes: Long,
    timestamp: String,
    backend: String = "raster",
): String {
    val sb = StringBuilder()
    sb.append("{\n  \"scenes\": [\n")
    results.forEachIndexed { i, m ->
        if (i > 0) sb.append(",\n")
        sb.append("    {\n")
        sb.append("      \"name\": \"${m.scene.sceneName}\",\n")
        sb.append("      \"frame_time_avg_ms\": ${fmt3(m.frameTimeAvgMs)},\n")
        sb.append("      \"frame_time_p50_ms\": ${fmt3(m.frameTimeP50Ms)},\n")
        sb.append("      \"frame_time_p99_ms\": ${fmt3(m.frameTimeP99Ms)},\n")
        sb.append("      \"frame_time_p999_ms\": ${fmt3(m.frameTimeP999Ms)},\n")
        sb.append("      \"jank_frames\": ${m.jankFrames},\n")
        sb.append("      \"jank_pct\": ${fmt1(m.jankPct)},\n")
        sb.append("      \"fps\": ${fmt1(m.fps)},\n")
        sb.append("      \"draw_calls_per_frame\": ${m.drawCallsPerFrame},\n")
        sb.append("      \"rss_mb\": ${fmt1(m.rssMb)},\n")
        sb.append("      \"ttff_ms\": ${fmt1(m.ttffMs)},\n")
        sb.append("      \"frames_rendered\": ${m.framesRendered},\n")
        if (m.extra.isEmpty()) {
            sb.append("      \"extra\": {}\n")
        } else {
            sb.append(
                m.extra.joinToString(", ", "      \"extra\": { ", " }\n") { (k, v) -> "\"$k\": $v" },
            )
        }
        sb.append("    }")
    }
    sb.append("\n  ],\n")
    sb.append("  \"binary_size_bytes\": $binarySizeBytes,\n")
    sb.append("  \"backend\": \"$backend\",\n")
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
        if (WINDOWED) {
            // Swing/AWT requires the EDT for the frame + layer; the harness
            // drives paint() synchronously, so the whole run lives there.
            var metrics: Metrics? = null
            SwingUtilities.invokeAndWait { metrics = Harness(scene).run() }
            metrics!!
        } else {
            Harness(scene).run()
        }
    }
    val now = Instant.now()
    val json = formatReport(
        results, binarySizeBytes(), isoTimestamp(now),
        if (WINDOWED) "skiko-metal" else "raster",
    )
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

    // 6. sendPointerEvent reaches a pointerInput handler (input_latency's
    //    mechanism): a Press at the center flips the response state and the
    //    next render paints it.
    var probeResponded by mutableStateOf(false)
    val scene5 = CanvasLayersComposeScene(
        density = Density(1f), size = IntSize(WIDTH, HEIGHT), coroutineContext = Dispatchers.Unconfined
    )
    scene5.setContent {
        Box(Modifier.fillMaxSize()) {
            Box(
                Modifier.size(200.dp).align(Alignment.Center)
                    .background(if (probeResponded) Color(0xFF03DAC6) else Color(0xFF7C4DFF))
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            awaitFirstDown()
                            probeResponded = true
                        }
                    }
            )
        }
    }
    surface.canvas.clear(BG_ARGB)
    scene5.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    val hashBeforePress = surfaceHash(surface)
    scene5.sendPointerEvent(PointerEventType.Press, Offset(WIDTH / 2f, HEIGHT / 2f))
    check("pointer press reaches handler", probeResponded)
    scene5.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    check("response paints next frame", surfaceHash(surface) != hashBeforePress)
    scene5.close()

    // 7. the merged semantics tree is walkable (semantics_build's mechanism).
    val scene6 = CanvasLayersComposeScene(
        density = Density(1f), size = IntSize(WIDTH, HEIGHT), coroutineContext = Dispatchers.Unconfined
    )
    scene6.setContent {
        Box(Modifier.fillMaxSize()) { Text("hi", color = Color.White) }
    }
    scene6.render(surface.canvas.asComposeCanvas(), System.nanoTime())
    val semNodes = run {
        val h = object {
            var n = 0L
        }
        try {
            val mainOwnerField = scene6.javaClass.getDeclaredField("mainOwner").apply { isAccessible = true }
            val owner = mainOwnerField.get(scene6).javaClass.getMethod("getOwner")
                .apply { isAccessible = true }.invoke(mainOwnerField.get(scene6))
            val ownerSemantics = owner.javaClass.getMethod("getSemanticsOwner")
                .apply { isAccessible = true }.invoke(owner) as SemanticsOwner
            fun walk(node: SemanticsNode) {
                h.n++
                node.children.forEach(::walk)
            }
            walk(ownerSemantics.rootSemanticsNode)
        } catch (e: Exception) {
            System.err.println("klaxon bench compose: probe: semantics walk failed: $e")
        }
        h.n
    }
    check("semantics tree walks", semNodes in 1..100, "semantics nodes=$semNodes")
    scene6.close()

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
