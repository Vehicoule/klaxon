// Bench.kt — the harness for the Android (Jetpack Compose) benchmark runner.
//
// A windowed/on-device sibling of the desktop runner (bench/runners/compose):
// the same scene catalogue subset (docs/specs/bench-scenes.md), the same
// 10 warmup + 120 measured frame contract, and the same JSON report shape as
// Klaxon's tier-2 Android run (src/bench.zig runAndroidSuite — scenes render on
// the activity's real GLES surface, report written to the app's files dir).
//
// Timing model — work-per-frame, vsync/presentation waits excluded:
//   Klaxon's timed span is tick + layout + paint (Skia op emission + GPU
//   command submission) minus eglSwapBuffers' paced wait (last_frame_wait_ns).
//   The Android equivalent is the per-frame phase breakdown delivered by
//   Window.OnFrameMetricsAvailableListener (the same pipeline JankStats /
//   androidx Macrobenchmark read):
//     work_ns = INPUT_HANDLING + ANIMATION + LAYOUT_MEASURE + DRAW
//             + SYNC + COMMAND_ISSUE
//   i.e. everything EXCEPT UNKNOWN_DELAY (dead time between the vsync and the
//   frame's first phase — scheduling latency, not work) and
//   SWAP_BUFFERS_DURATION (the eglSwapBuffers present wait — Klaxon's
//   subtracted last_frame_wait_ns). ANIMATION_DURATION is where Compose's
//   recomposition runs (the Recomposer is driven by Choreographer frame
//   callbacks), so the span covers recompose + measure/layout + display-list
//   draw + RenderThread sync + GPU command issue — the Compose analog of
//   Klaxon's frame. GPU_DURATION (async raster; SwiftShader on the emulator)
//   is reported separately as gpu_frame_time_avg_ms.
//
// Scene clock — one scene tick per presented frame:
//   Klaxon calls tick() then paints every vsync-cycle frame. An idiomatic
//   Compose equivalent can't tick per vsync: on a device where the render
//   pipeline drops vsyncs (the emulator's SwiftShader stack presents ~30fps
//   on a 60Hz display), two vsync ticks' worth of state mutation would merge
//   into a single presented frame — e.g. mount_churn would pay 100 swaps in
//   one frame instead of 50. So the tick runs once per frame the UI thread
//   actually draws: inside the root drawBehind lambda, which also writes a
//   `heartbeat` state it reads — every recorded frame re-invalidates the
//   root draw scope for the next traversal, so frames are produced as fast
//   as the pipeline will take them, each carrying exactly one scene tick
//   (one scroll step, one churn batch, one IME commit — Klaxon's contract).
//   The scene's `frame` argument is the presented-frame index.
//
// Metric definitions mirror bench.zig (+ schema v2):
//   - fps: 1000 / frame_time_avg_ms over measured presented frames.
//   - presented_fps: presented frames in the measured window / wall clock,
//     like Klaxon's frames_presented / wall.
//   - frame_time_*: per-frame frame-work ms (see above), nearest-rank
//     percentiles like bench.zig's percentile().
//   - jank_frames / jank_pct: frames with frame_ms > 16.67 (60 Hz budget).
//   - ttff_ms: scene start (SceneState + composition included) -> the END of
//     the first presented frame (vsync + TOTAL_DURATION).
//   - draw_calls_per_frame: placed LayoutNodes after the final frame
//     (Klaxon's countPaintNodes analog — same reflection bridge as the
//     desktop runner: Owner.getRoot -> LayoutNode.getChildren / isPlaced).
//   - rss_mb: process RSS via /proc/self/status VmRSS.
//   - frames_rendered: presented frames (10 warmup + 120 measured = 130 like
//     Klaxon; fewer if the run hits the safety timeout).
//   - dropped_frames: frames the pipeline dropped between metrics events
//     (FrameMetrics dropCount — e.g. ~120 on a 30fps presentation).
//   - gpu_frame_time_avg_ms: GPU_DURATION mean (async raster; null if the
//     platform doesn't report it). SwiftShader raster happens off the
//     measured UI/RT phases — shown for context, not part of fps.
//   - extra: same contract keys as bench.zig formatExtra (nulls when unset);
//     ramp scenes fill ramp[] + n_max_60fps.

package bench.compose

import android.util.Log
import android.view.FrameMetrics
import android.view.View
import android.view.ViewGroup
import android.view.Window
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.floor
import kotlin.math.min
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/** Harness settings — the docs/specs/bench-scenes.md schema-v2 contract. */
const val WARMUP_FRAMES = 10
const val MEASURED_FRAMES = 120

/** 60 Hz frame budget for the schema-v2 jank metrics (Macrobenchmark/JankStats). */
const val JANK_BUDGET_MS = 16.67

/** ramp (MotionMark): the stepped item counts, 10 warmup + 20 measured per step. */
val RAMP_STEPS = listOf(10, 25, 50, 100, 200, 400, 800, 1600, 3200)
const val RAMP_WARMUP_FRAMES = 10
const val RAMP_MEASURED_FRAMES = 20

private const val TAG = "KlaxonBench"

/**
 * Safety nets. Presentation on the SwiftShader emulator runs at ~half the
 * vsync rate even for trivial scenes, and heavy ramp steps crawl — the
 * deadline is a wall-clock cap per scene so a wedged pipeline still yields
 * a (partial) report.
 */
private const val SCENE_TIMEOUT_NORMAL_MS = 120_000L
private const val SCENE_TIMEOUT_RAMP_MS = 420_000L

/** Settle time before the suite and between scenes (drains stray metrics). */
private const val SUITE_SETTLE_MS = 1_500L
private const val INTER_SCENE_MS = 300L

/// How a scene's frames are scheduled (docs/specs/bench-scenes.md).
enum class SceneKind {
    /** 10 warmup + 120 measured presented frames (the default contract). */
    NORMAL,

    /** RAMP_STEPS item counts; 10 warmup + 20 measured presented frames per step. */
    RAMP,
}

/// The implemented subset of the canonical catalogue (the full 33-scene list
/// lives in bench.zig / the desktop runner's BenchScene enum).
enum class BenchScene(val sceneName: String, val kind: SceneKind = SceneKind.NORMAL) {
    HELLO("hello"),
    SCROLL_10K("scroll_10k"),
    ANIM_100("anim_100"),
    INPUT_IME("input_ime"),
    ELEVATION_GRID("elevation_grid"),
    MOUNT_CHURN("mount_churn"),
    SHAPES_RAMP("shapes_ramp", SceneKind.RAMP),
    TEXT_RAMP("text_ramp", SceneKind.RAMP),
    IMAGES_RAMP("images_ramp", SceneKind.RAMP);

    companion object {
        fun fromName(name: String): BenchScene? = entries.firstOrNull { it.sceneName == name }
    }
}

/// Collected metrics for one scene run (bench.zig Metrics + schema v2).
data class Metrics(
    val scene: BenchScene,
    val fps: Double,
    val presentedFps: Double,
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
    val drawnFrames: Long,
    val droppedFrames: Long,
    val gpuFrameTimeAvgMs: Double?,
    /** raw JSON fragments for the schema-v2 extra object (already-encoded). */
    val extra: Map<String, String>,
)

/// The bench suite: scene ticks run inside the root draw lambda (one per
/// recorded frame — see the header note) and Window.OnFrameMetricsAvailableListener
/// supplies each presented frame's phase breakdown. The run ends when the
/// measured presented-frame quota is collected (or the safety timeout hits).
class BenchRunner(private val activity: BenchmarkActivity) :
    Window.OnFrameMetricsAvailableListener {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** The scene content currently rendered (null = idle background). */
    var currentState by mutableStateOf<SceneState?>(null)
        private set

    /** Written once per recorded frame; read in the root drawBehind so every
     *  recorded frame re-invalidates the root draw scope for the next
     *  traversal — the frame-production loop (see header). */
    val heartbeat = mutableLongStateOf(0L)

    /** On-screen + logcat progress. */
    var statusText by mutableStateOf("idle")
        private set

    /** Signals report completion (activity can show/finish). */
    var suiteDone by mutableStateOf(false)
        private set

    // --- per-run buffers (indexed by presented-frame / metrics-event index) ---
    private var runTarget = 0          // presented frames to collect
    private var warmupCount = WARMUP_FRAMES
    private var measuredCount = MEASURED_FRAMES
    private var eventIdx = 0           // FrameMetrics events seen this run
    private var drawnFrames = 0L       // root-draw executions this run (scene ticks)
    private var droppedFrames = 0L     // sum of dropCountSinceLastInvocation
    private var workMs = DoubleArray(0)     // frame-work ms per presented frame
    private var gpuNs = LongArray(0)        // GPU_DURATION per presented frame
    private var frameEndNs = LongArray(0)   // vsync + TOTAL_DURATION
    private var runStartNs = 0L
    private var firstFrameEndNs = 0L
    private var firstMeasuredVsyncNs = 0L
    private var strayMetrics = 0       // events while a run isn't collecting
    private var runGate: CompletableDeferred<Unit>? = null
    private var running = false

    /** Set via intent extra `-ez debug true`: logs raw metrics phases. */
    var debugLog = false

    // --- launch ---

    fun launch(scenes: List<BenchScene>, warmup: Int, measured: Int) {
        warmupCount = warmup
        measuredCount = measured
        scope.launch {
            delay(SUITE_SETTLE_MS) // first composition + surface warm-up
            val results = ArrayList<Metrics>(scenes.size)
            scenes.forEachIndexed { i, scene ->
                statusText = "${scene.sceneName} (${i + 1}/${scenes.size})"
                Log.i(TAG, "scene ${scene.sceneName} (${i + 1}/${scenes.size})")
                try {
                    results += runScene(scene)
                } catch (t: Throwable) {
                    Log.e(TAG, "scene ${scene.sceneName} failed", t)
                }
                delay(INTER_SCENE_MS)
            }
            val json = formatReport(results, binarySizeBytes(), "compose-hwui-gles")
            writeReport(json)
            Log.i(TAG, "report written (${results.size} scenes)")
            statusText = "done — files/bench-compose.json"
            suiteDone = true
        }
    }

    // --- one scene run ---

    private fun targetFrames(scene: BenchScene) = when (scene.kind) {
        SceneKind.RAMP -> RAMP_STEPS.size * (RAMP_WARMUP_FRAMES + RAMP_MEASURED_FRAMES)
        SceneKind.NORMAL -> warmupCount + measuredCount
    }

    private suspend fun runScene(scene: BenchScene): Metrics {
        val st = SceneState(scene)
        resetRun(targetFrames(scene))
        running = true
        runStartNs = System.nanoTime()
        val gate = CompletableDeferred<Unit>()
        runGate = gate
        // Publish the scene — the first traversal records it and the root
        // draw lambda's heartbeat keeps the frame loop going from there.
        heartbeat.longValue++
        currentState = st
        val timeout = if (scene.kind == SceneKind.RAMP) SCENE_TIMEOUT_RAMP_MS else SCENE_TIMEOUT_NORMAL_MS
        try {
            withTimeout(timeout) { gate.await() }
        } catch (t: Throwable) {
            Log.e(TAG, "${scene.sceneName}: timed out at $eventIdx/$runTarget presented frames", t)
        }
        if (strayMetrics > 0) {
            Log.w(TAG, "${scene.sceneName}: $strayMetrics stray metric event(s)")
        }
        val m = finishMetrics(scene, st)
        running = false
        currentState = null
        Log.i(
            TAG,
            "${scene.sceneName}: presented=$eventIdx drawn=$drawnFrames dropped=$droppedFrames " +
                "avg=${"%.2f".format(Locale.ROOT, m.frameTimeAvgMs)}ms fps=${"%.1f".format(Locale.ROOT, m.fps)}",
        )
        return m
    }

    private fun resetRun(target: Int) {
        runTarget = target
        eventIdx = 0
        drawnFrames = 0L
        droppedFrames = 0L
        workMs = DoubleArray(target) { Double.NaN }
        gpuNs = LongArray(target)
        frameEndNs = LongArray(target)
        firstFrameEndNs = 0L
        firstMeasuredVsyncNs = 0L
        strayMetrics = 0
        runGate = null
    }

    // --- the scene tick, once per recorded frame (root drawBehind) ---

    /**
     * Called from the root drawBehind lambda while the UI thread records a
     * frame. Runs exactly one scene tick per recorded frame — the scene's
     * `frame` is the presented-frame index, matching Klaxon's one-tick-per-
     * frame contract even when the vsync cadence outruns presentation.
     * The heartbeat self-write re-invalidates this draw scope so the next
     * traversal draws again — frames are produced as fast as the pipeline
     * records them, and stop the moment the run ends.
     */
    fun onSceneFrame() {
        if (!running) return
        val st = currentState ?: return
        val i = drawnFrames++
        try {
            st.tick(i) // scene logic: state writes land in the NEXT frame
        } catch (t: Throwable) {
            Log.e(TAG, "${st.scene.sceneName}: tick $i failed", t)
            running = false
            runGate?.complete(Unit)
            return
        }
        heartbeat.longValue++ // must CHANGE every frame to keep the loop alive
        if (debugLog && i < 8) Log.i(TAG, "draw[$i] t=${System.nanoTime()}")
    }

    // --- FrameMetrics (UI thread, one event per presented frame) ---

    override fun onFrameMetricsAvailable(
        window: Window?,
        metrics: FrameMetrics?,
        dropCountSinceLastInvocation: Int,
    ) {
        if (metrics == null) return
        if (!running || eventIdx >= runTarget) {
            // In-flight frames from before/after the run (or past the quota).
            if (running) strayMetrics++
            return
        }
        val vsync = metrics.getMetric(FrameMetrics.VSYNC_TIMESTAMP)
        if (vsync <= 0) return
        droppedFrames += dropCountSinceLastInvocation

        // Frame work = every phase except UNKNOWN_DELAY (scheduling latency
        // between vsync and traversal start) and SWAP_BUFFERS (the
        // eglSwapBuffers presentation wait — Klaxon's subtracted
        // last_frame_wait_ns).
        val workNs = metrics.getMetric(FrameMetrics.INPUT_HANDLING_DURATION) +
            metrics.getMetric(FrameMetrics.ANIMATION_DURATION) +
            metrics.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION) +
            metrics.getMetric(FrameMetrics.DRAW_DURATION) +
            metrics.getMetric(FrameMetrics.SYNC_DURATION) +
            metrics.getMetric(FrameMetrics.COMMAND_ISSUE_DURATION)
        val i = eventIdx++
        workMs[i] = workNs / 1e6
        gpuNs[i] = metrics.getMetric(FrameMetrics.GPU_DURATION)
        frameEndNs[i] = vsync + metrics.getMetric(FrameMetrics.TOTAL_DURATION)
        if (firstFrameEndNs == 0L) firstFrameEndNs = frameEndNs[i]
        if (i == warmupCount) firstMeasuredVsyncNs = frameEndNs[warmupCount - 1]
        if (debugLog && i < 8) {
            Log.i(
                TAG,
                "fm[$i] vsync=$vsync anim=${metrics.getMetric(FrameMetrics.ANIMATION_DURATION)} " +
                    "ml=${metrics.getMetric(FrameMetrics.LAYOUT_MEASURE_DURATION)} " +
                    "draw=${metrics.getMetric(FrameMetrics.DRAW_DURATION)} " +
                    "sync=${metrics.getMetric(FrameMetrics.SYNC_DURATION)} " +
                    "ci=${metrics.getMetric(FrameMetrics.COMMAND_ISSUE_DURATION)} " +
                    "swap=${metrics.getMetric(FrameMetrics.SWAP_BUFFERS_DURATION)} " +
                    "gpu=${gpuNs[i]} total=${metrics.getMetric(FrameMetrics.TOTAL_DURATION)} " +
                    "dropped=$dropCountSinceLastInvocation",
            )
        }
        if (eventIdx >= runTarget) runGate?.complete(Unit)
    }

    // --- stats (bench.zig finishMetrics / runRamp) ---

    private fun measuredRanges(scene: BenchScene): List<IntRange> = when (scene.kind) {
        SceneKind.RAMP -> RAMP_STEPS.indices.map { s ->
            val base = s * (RAMP_WARMUP_FRAMES + RAMP_MEASURED_FRAMES) + RAMP_WARMUP_FRAMES
            base until (base + RAMP_MEASURED_FRAMES).coerceAtMost(eventIdx)
        }
        SceneKind.NORMAL -> listOf(warmupCount until (warmupCount + measuredCount).coerceAtMost(eventIdx))
    }

    private fun finishMetrics(scene: BenchScene, st: SceneState): Metrics {
        val ranges = measuredRanges(scene)
        val measuredWork = ArrayList<Double>()
        val extras = LinkedHashMap<String, String>()

        if (scene.kind == SceneKind.RAMP) {
            val ramp = ArrayList<Pair<Int, Double>>(RAMP_STEPS.size)
            RAMP_STEPS.forEachIndexed { s, n ->
                val step = ranges[s].mapNotNull { workMs[it].takeIf { w -> !w.isNaN() } }
                val sorted = step.sorted()
                ramp += n to percentileSorted(sorted, 50.0)
                measuredWork += step
            }
            extras["ramp"] = ramp.joinToString(", ", "[", "]") { (n, p50) ->
                "{\"n\": $n, \"p50_ms\": ${fmt2(p50)}}"
            }
            extras["n_max_60fps"] =
                (ramp.lastOrNull { it.second <= JANK_BUDGET_MS }?.first ?: 0).toString()
        } else {
            ranges.forEach { r -> r.forEach { i -> if (!workMs[i].isNaN()) measuredWork += workMs[i] } }
        }

        val sorted = measuredWork.sorted()
        val avg = if (sorted.isEmpty()) 0.0 else sorted.average()
        val jank = sorted.count { it > JANK_BUDGET_MS }

        // presented_fps: every presented frame in the wall window (end of the
        // last warmup -> end of the last measured frame) — the window includes
        // ramp-step warmups too, so count events, not just measured samples.
        val lastIdx = ranges.last().lastOrNull() ?: -1
        val presented = if (lastIdx > warmupCount) lastIdx - warmupCount + 1 else 0
        val wallEnd = if (lastIdx >= 0) frameEndNs[lastIdx] else 0L
        val wallNs = if (firstMeasuredVsyncNs > 0 && wallEnd > firstMeasuredVsyncNs)
            wallEnd - firstMeasuredVsyncNs else 0
        val presentedFps = if (wallNs > 0) presented * 1e9 / wallNs else 0.0

        // GPU raster (async): mean over the measured window when reported.
        val gpuSamples = ranges.flatMap { r -> r.map { gpuNs[it] } }.filter { it > 0 }
        val gpuAvg = if (gpuSamples.isEmpty()) null else gpuSamples.average() / 1e6

        val ttffMs = if (firstFrameEndNs > 0) (firstFrameEndNs - runStartNs) / 1e6 else 0.0
        return Metrics(
            scene = scene,
            fps = if (avg > 0) 1000.0 / avg else 0.0,
            presentedFps = presentedFps,
            frameTimeAvgMs = avg,
            frameTimeP50Ms = percentileSorted(sorted, 50.0),
            frameTimeP99Ms = percentileSorted(sorted, 99.0),
            frameTimeP999Ms = percentileSorted(sorted, 99.9),
            jankFrames = jank.toLong(),
            jankPct = if (sorted.isEmpty()) 0.0 else 100.0 * jank / sorted.size,
            drawCallsPerFrame = countPlacedLayoutNodes(),
            rssMb = readRssMb(),
            ttffMs = ttffMs,
            framesRendered = eventIdx.toLong(),
            drawnFrames = drawnFrames,
            droppedFrames = droppedFrames,
            gpuFrameTimeAvgMs = gpuAvg,
            extra = extras,
        )
    }

    /** bench.zig percentile(): nearest-rank over an ascending-sorted list. */
    private fun percentileSorted(sorted: List<Double>, p: Double): Double {
        if (sorted.isEmpty()) return 0.0
        val idx = floor(sorted.size * p / 100.0).toInt()
        return sorted[min(idx, sorted.size - 1)]
    }

    // --- draw_calls_per_frame: placed LayoutNodes (reflection bridge, same
    //     approach as the desktop runner) ---

    private val layoutNodeClass by lazy { Class.forName("androidx.compose.ui.node.LayoutNode") }
    private val childrenGetter by lazy {
        layoutNodeClass.declaredMethods.firstOrNull {
            it.parameterCount == 0 && (it.name == "getChildren" || it.name.startsWith("getChildren$"))
        }?.apply { isAccessible = true }
    }
    private val isPlacedGetter by lazy {
        layoutNodeClass.methods.firstOrNull {
            it.parameterCount == 0 && (it.name == "isPlaced" || it.name.startsWith("isPlaced$"))
        }?.apply { isAccessible = true }
    }

    private fun findComposeOwnerRoot(view: View?): Any? {
        // content frame -> ComposeView -> AndroidComposeView (the Owner).
        val vg = view as? ViewGroup ?: return null
        for (i in 0 until vg.childCount) {
            val child = vg.getChildAt(i)
            val getRoot = child.javaClass.methods.firstOrNull {
                it.parameterCount == 0 && (it.name == "getRoot" || it.name.startsWith("getRoot$"))
            }
            if (getRoot != null && child.javaClass.name.contains("AndroidComposeView")) {
                return try {
                    getRoot.apply { isAccessible = true }.invoke(child)
                } catch (e: Exception) {
                    null
                }
            }
            val deep = findComposeOwnerRoot(child)
            if (deep != null) return deep
        }
        return null
    }

    private fun countPlacedLayoutNodes(): Long {
        return try {
            val content = activity.findViewById<ViewGroup>(android.R.id.content)
            val root = findComposeOwnerRoot(content) ?: return 0
            countPlaced(root)
        } catch (e: Exception) {
            Log.w(TAG, "layout-node counting failed: $e")
            0
        }
    }

    private fun countPlaced(node: Any): Long {
        val placed = isPlacedGetter?.let { (it.invoke(node) as? Boolean) ?: true } ?: true
        if (!placed) return 0
        var count = 1L
        val getter = childrenGetter ?: return count
        @Suppress("UNCHECKED_CAST")
        val children = getter.invoke(node) as? Collection<Any> ?: return count
        for (child in children) count += countPlaced(child)
        return count
    }

    // --- rss_mb: /proc/self/status VmRSS (KiB -> MiB) ---

    private fun readRssMb(): Double {
        return try {
            File("/proc/self/status").useLines { lines ->
                val line = lines.firstOrNull { it.startsWith("VmRSS:") } ?: return 0.0
                val kb = line.removePrefix("VmRSS:").trim().removeSuffix("kB").trim().toDouble()
                kb / 1024.0
            }
        } catch (e: Exception) {
            0.0
        }
    }

    // --- report (bench.zig formatReport / formatExtra — same field names,
    //     order, and number formatting) ---

    private fun fmt1(v: Double) = String.format(Locale.ROOT, "%.1f", v)
    private fun fmt2(v: Double) = String.format(Locale.ROOT, "%.2f", v)

    private fun binarySizeBytes(): Long = try {
        File(activity.packageManager.getPackageInfo(activity.packageName, 0)
            .applicationInfo!!.sourceDir).length()
    } catch (e: Exception) {
        0L
    }

    private fun formatReport(results: List<Metrics>, binarySize: Long, backend: String): String {
        val ts = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.ROOT)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date())
        val sb = StringBuilder()
        sb.append("{\n  \"scenes\": [\n")
        results.forEachIndexed { i, m ->
            if (i > 0) sb.append(",\n")
            sb.append("    {\n")
            sb.append("      \"name\": \"${m.scene.sceneName}\",\n")
            sb.append("      \"fps\": ${fmt1(m.fps)},\n")
            sb.append("      \"presented_fps\": ${fmt1(m.presentedFps)},\n")
            sb.append("      \"frame_time_avg_ms\": ${fmt2(m.frameTimeAvgMs)},\n")
            sb.append("      \"frame_time_p50_ms\": ${fmt2(m.frameTimeP50Ms)},\n")
            sb.append("      \"frame_time_p99_ms\": ${fmt2(m.frameTimeP99Ms)},\n")
            sb.append("      \"frame_time_p999_ms\": ${fmt2(m.frameTimeP999Ms)},\n")
            sb.append("      \"jank_frames\": ${m.jankFrames},\n")
            sb.append("      \"jank_pct\": ${fmt1(m.jankPct)},\n")
            sb.append("      \"draw_calls_per_frame\": ${m.drawCallsPerFrame},\n")
            sb.append("      \"rss_mb\": ${fmt1(m.rssMb)},\n")
            sb.append("      \"ttff_ms\": ${fmt1(m.ttffMs)},\n")
            sb.append("      \"frames_rendered\": ${m.framesRendered},\n")
            // Android-runner transparency fields (not in Klaxon's schema):
            sb.append("      \"dropped_frames\": ${m.droppedFrames},\n")
            sb.append("      \"drawn_frames\": ${m.drawnFrames},\n")
            sb.append("      \"gpu_frame_time_avg_ms\": ${m.gpuFrameTimeAvgMs?.let { fmt2(it) } ?: "null"},\n")
            // Klaxon's formatExtra emits every contract key; unset -> null.
            val e = m.extra
            sb.append(
                "      \"extra\": {\"op_ms\": ${e["op_ms"] ?: "null"}, " +
                    "\"ramp\": ${e["ramp"] ?: "null"}, " +
                    "\"n_max_60fps\": ${e["n_max_60fps"] ?: "null"}, " +
                    "\"latency_ms\": ${e["latency_ms"] ?: "null"}, " +
                    "\"latency_frames\": ${e["latency_frames"] ?: "null"}, " +
                    "\"nodes_per_frame\": ${e["nodes_per_frame"] ?: "null"}, " +
                    "\"teardown_ms\": ${e["teardown_ms"] ?: "null"}, " +
                    "\"resume_ms\": ${e["resume_ms"] ?: "null"}}\n",
            )
            sb.append("    }")
        }
        sb.append("\n  ],\n")
        sb.append("  \"binary_size_bytes\": $binarySize,\n")
        sb.append("  \"backend\": \"$backend\",\n")
        sb.append("  \"timestamp\": \"$ts\"\n")
        sb.append("}\n")
        return sb.toString()
    }

    private fun writeReport(json: String) {
        // filesDir mirrors Klaxon's files/bench.json (run-as <pkg>).
        try {
            File(activity.filesDir, "bench-compose.json").writeText(json)
            Log.i(TAG, "wrote ${activity.filesDir}/bench-compose.json")
        } catch (e: Exception) {
            Log.e(TAG, "filesDir write failed", e)
        }
        // The app-specific external dir is adb-pull-able without run-as.
        try {
            File(activity.getExternalFilesDir(null), "bench-compose.json").writeText(json)
            Log.i(TAG, "wrote ${activity.getExternalFilesDir(null)}/bench-compose.json")
        } catch (e: Exception) {
            Log.e(TAG, "externalFilesDir write failed", e)
        }
    }
}
