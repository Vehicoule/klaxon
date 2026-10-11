// Scenes.kt — the 9 canonical scenes (Klaxon src/bench.zig) ported to Compose,
// the per-frame tick logic that drives them (the bench.zig SceneRunner.tick
// analog), and the closed-form spring used by anim_100 (src/ui/anim.zig parity).
// SceneState also carries the state for the 24 schema-v2 scenes
// (docs/specs/bench-scenes.md) and dispatches to their ticks/composables in
// ScenesListOps.kt / ScenesRamp.kt / ScenesStress.kt / ScenesSystem.kt.
//
// Scene structure, strings, sizes, colors and the tick cadence mirror bench.zig
// as closely as Compose allows; the known non-parities are documented in
// bench/runners/compose/README.md.

package bench.compose

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Badge
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asComposeImageBitmap
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.runBlocking
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.ColorAlphaType
import org.jetbrains.skia.ImageInfo
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/** Klaxon's bench background (bench.zig BG: 0x14141CFF, RRGGBBAA). */
val BG = Color(0xFF14141C)

/** The schema-v2 catalogue palette (bench-scenes.md): #7C4DFF / #03DAC6. */
val PURPLE = Color(0xFF7C4DFF)
val TEAL = Color(0xFF03DAC6)

/** anim_100: the widget count (bench.zig ANIM_WIDGETS). */
const val ANIM_WIDGETS = 100

/** resize: the viewport cycle (bench.zig RESIZE_SIZES). */
val RESIZE_SIZES = listOf(640 to 480, 480 to 320, 320 to 240, 800 to 600, 240 to 400, 960 to 640)

/** input_ime: the IME commit strings (bench.zig IME_STRINGS). */
val IME_STRINGS = listOf("こんにちは", "世界", "안녕하세요", "你好，世界", "🌍 ", "🎉 ")

/** video_playback: the simulated stream size (bench.zig videoWidget 320x180). */
const val VIDEO_W = 320
const val VIDEO_H = 180

// anim_100 colors, as ARGB ints (Klaxon packs colors 0xRRGGBBAA; Compose Color
// takes 0xAARRGGBB — same channels). Klaxon: lerpColor(0x3F51B5FF, 0xE91E63FF, t).
private val INDIGO = 0xFF3F51B5.toInt()
private val PINK = 0xFFE91E63.toInt()

/// Klaxon's closed-form spring (src/ui/anim.zig Spring{stiffness=380,
/// damping=32, mass=1}), retargeted every frame with v0 = 0 and advanced
/// t = 8 ms per frame. Underdamped (zeta = 32 / (2*sqrt(380)) ~ 0.82), so the
/// displacement from the target d0 = from - to evolves as
///   d(t) = e * (d0*cos(wd*t) + ((z*w0)/wd)*d0*sin(wd*t))
/// and one frame multiplies the displacement by the factor k below.
private val SPRING_STEP_FACTOR: Double by lazy {
    val stiffness = 380.0
    val damping = 32.0
    val mass = 1.0
    val omega0 = sqrt(stiffness / mass)
    val zeta = damping / (2 * sqrt(stiffness * mass))
    val omegaD = omega0 * sqrt(1 - zeta * zeta)
    val t = 0.008
    exp(-zeta * omega0 * t) * (cos(omegaD * t) + (zeta * omega0 / omegaD) * sin(omegaD * t))
}

/// One 0..255 channel step toward the target (Klaxon truncates, like vec4ToColor).
private fun stepChannel(from: Int, to: Int, k: Double) = (to + k * (from - to)).toInt()

/// Klaxon's lerpColor on ARGB-packed channels (truncating, like anim.zig).
private fun lerpColorArgb(a: Int, b: Int, t: Float): Int {
    fun lane(x: Int, y: Int) = (x + (y - x) * t).coerceIn(0f, 255f).toInt()
    return (lane((a shr 24) and 0xFF, (b shr 24) and 0xFF) shl 24) or
        (lane((a shr 16) and 0xFF, (b shr 16) and 0xFF) shl 16) or
        (lane((a shr 8) and 0xFF, (b shr 8) and 0xFF) shl 8) or
        lane(a and 0xFF, b and 0xFF)
}

/// Drop the last Unicode code point (a backspace; surrogate-pair safe for emoji).
private fun String.dropLastCodePoint(): String {
    if (isEmpty()) return this
    var end = length - 1
    if (end > 0 && this[end - 1].isLowSurrogate() && this[end].isHighSurrogate()) end--
    return substring(0, end)
}

/// One scene's live state plus the tick that drives it per frame (the bench.zig
/// SceneRunner analog). State is plain Compose snapshot state, so writing it in
/// tick() invalidates the affected scopes and the next scene.render() recomposes.
class SceneState(val scene: BenchScene) {
    /** scroll_10k / scroll_anim / backdrop_scroll: published from composition via rememberLazyListState. */
    var listState: LazyListState? = null

    /** backdrop_scroll: the blurred copy of the list mirrors the scroller. */
    var listState2: LazyListState? = null

    // --- anim_100: 100 widgets x (height + color) spring lanes ---
    val heights = Array(ANIM_WIDGETS) { mutableStateOf(32f) }
    val colors = Array(ANIM_WIDGETS) { mutableStateOf(INDIGO) }

    // --- input_ime ---
    var text by mutableStateOf("")

    // --- video_playback ---
    var videoFrame by mutableStateOf(0L)

    // --- schema-v2 additions (docs/specs/bench-scenes.md) ---

    /** The rendered frame index — the shared animation clock every ramp/stress
     *  scene derives positions/phase from. Written once per tick. */
    val animFrame = mutableLongStateOf(0L)

    /** ramp: the current step's item count (set by the harness per step). */
    val rampItemCount = mutableIntStateOf(0)

    // --- list_ops (Family A) ---
    val listRows = mutableStateListOf<ListRowModel>()
    var listRowNextId = 0

    // --- mount_churn ---
    val churnPool = mutableStateListOf<Long>()
    var churnNextId = 0L

    /** Shared deterministic LCG for the stress family (churn victims, chart noise). */
    var lcg = 0x2B992DD5L

    // --- chart_live ---
    val chartData = DoubleArray(CHART_POINTS)
    var chartPhase = 0L

    // --- theme_switch ---
    var themePalette by mutableStateOf(DARK_PALETTE)

    // --- input_latency ---
    /** Set by the pointerInput handler when the injected event is delivered. */
    var responseArrived = false
    var responseColor by mutableStateOf(PURPLE)
    private var requestPointerInjection = false

    /** input_latency's tick arms the injection; the harness fires it once. */
    fun requestPointerInjection() {
        requestPointerInjection = true
    }

    fun consumePointerInjection(): Boolean {
        val r = requestPointerInjection
        requestPointerInjection = false
        return r
    }

    // --- semantics_build ---
    /** One state per node so a frame's description writes invalidate only the
     *  rotating window's semantics (the incremental rebuild half of
     *  "build/diff the semantics tree"). */
    val semStates = Array(SEMANTICS_NODES) { mutableLongStateOf(0L) }
    var semNodesSum = 0L
    var semNodesSamples = 0L

    // --- app_switch ---
    var teardownSumMs = 0.0
    var resumeSumMs = 0.0
    var switchCycles = 0

    fun recordSwitchCycle(teardownMs: Double, resumeMs: Double) {
        teardownSumMs += teardownMs
        resumeSumMs += resumeMs
        switchCycles++
    }

    /** Scene-extras (schema v2 `extra: {}`), key -> raw JSON value fragment. */
    val extras = LinkedHashMap<String, String>()

    fun putExtra(key: String, rawJson: String) {
        extras[key] = rawJson
    }

    init {
        when (scene) {
            BenchScene.LIST_CREATE_1K, BenchScene.LIST_REPLACE_1K, BenchScene.LIST_UPDATE_10TH,
            BenchScene.LIST_SWAP_ROWS, BenchScene.LIST_REMOVE_ROW, BenchScene.LIST_CLEAR_1K,
            -> initListOps()

            BenchScene.MOUNT_CHURN -> repeat(CHURN_POOL_SIZE) { churnPool += churnNextId++ }
            BenchScene.CHART_LIVE -> initChart()
            else -> {}
        }
    }

    /// Per-frame scene logic, before recomposition + layout + draw.
    /// Deterministic in `frame` (bench.zig SceneRunner.tick).
    fun tick(frame: Long, harness: Harness) {
        when (scene) {
            BenchScene.HELLO, BenchScene.TEXT_CJK, BenchScene.GLASS_BLUR, BenchScene.GALLERY -> {
                // static trees
            }

            BenchScene.SCROLL_10K -> {
                // Klaxon: off = (frame*37) mod (maxScroll+1); item height 36,
                // viewport 300 -> maxScroll = 10_000*36 - 300. Frame 0 targets
                // offset 0 (a no-op) and also runs before the first layout,
                // which LazyListState.scrollToItem would wait for.
                if (frame > 0) {
                    val maxOff = 10_000 * 36 - 300
                    val off = (frame * 37) % (maxOff + 1)
                    runBlocking { listState!!.scrollToItem((off / 36).toInt(), (off % 36).toInt()) }
                }
            }

            BenchScene.ANIM_100 -> {
                // Klaxon retargets every widget every frame (phase = frame*0.06
                // + i*0.17; height 24+16*sin(phase); color lerp indigo->pink)
                // and advances the timeline 8 ms/frame. Each retarget starts a
                // spring from the current value with v0 = 0, so one frame steps
                // every lane toward the new target by the closed-form factor.
                val k = SPRING_STEP_FACTOR
                for (i in 0 until ANIM_WIDGETS) {
                    val phase = frame * 0.06 + i * 0.17
                    val s = sin(phase)
                    val targetH = (24 + 16 * s).toFloat()
                    heights[i].value = (targetH + k * (heights[i].value - targetH)).toFloat()
                    val target = lerpColorArgb(INDIGO, PINK, ((s + 1) / 2).toFloat())
                    val c = colors[i].value
                    colors[i].value =
                        (stepChannel((c shr 24) and 0xFF, (target shr 24) and 0xFF, k) shl 24) or
                            (stepChannel((c shr 16) and 0xFF, (target shr 16) and 0xFF, k) shl 16) or
                            (stepChannel((c shr 8) and 0xFF, (target shr 8) and 0xFF, k) shl 8) or
                            stepChannel(c and 0xFF, target and 0xFF, k)
                }
            }

            BenchScene.RESIZE -> {
                // Cycle the viewport: resize the scene + surface, relayout.
                val (w, h) = RESIZE_SIZES[(frame % RESIZE_SIZES.size).toInt()]
                harness.resizeScene(w, h)
            }

            BenchScene.INPUT_IME -> {
                // The IME commit path: append one of the strings; a backspace
                // every 12th frame keeps the buffer bounded (like bench.zig).
                if (frame % 12 == 11L) {
                    text = text.dropLastCodePoint()
                } else {
                    text += IME_STRINGS[(frame % IME_STRINGS.size).toInt()]
                }
            }

            BenchScene.VIDEO_PLAYBACK -> {
                videoFrame = frame // the widget regenerates its "frame" at paint
            }

            // --- schema-v2 families (ScenesListOps/Ramp/Stress/System.kt) ---

            BenchScene.LIST_CREATE_1K, BenchScene.LIST_REPLACE_1K, BenchScene.LIST_UPDATE_10TH,
            BenchScene.LIST_SWAP_ROWS, BenchScene.LIST_REMOVE_ROW, BenchScene.LIST_CLEAR_1K,
            -> tickListOps(frame, harness)

            BenchScene.SHAPES_RAMP, BenchScene.PATHS_RAMP, BenchScene.TEXT_RAMP,
            BenchScene.IMAGES_RAMP,
            -> tickRamp(frame, harness)

            BenchScene.OVERDRAW_STACK, BenchScene.ELEVATION_GRID, BenchScene.RELAYOUT_STORM,
            BenchScene.MOUNT_CHURN, BenchScene.SCROLL_ANIM, BenchScene.TEXT_RICH,
            BenchScene.CHART_LIVE, BenchScene.CLIP_PATH, BenchScene.THEME_SWITCH,
            BenchScene.BACKDROP_SCROLL,
            -> tickStress(frame, harness)

            BenchScene.INPUT_LATENCY, BenchScene.POINTER_STORM, BenchScene.SEMANTICS_BUILD,
            BenchScene.APP_SWITCH,
            -> tickSystem(frame, harness)
        }
    }

    /// Timed post-render work (inside the frame's timed region, after
    /// scene.render). Only semantics_build uses it: the a11y-tree walk belongs
    /// to the measured frame it follows.
    fun postRender(frame: Long, harness: Harness) {
        when (scene) {
            BenchScene.SEMANTICS_BUILD -> postRenderSemantics(frame, harness)
            else -> {}
        }
    }

    /// Derive the final `extra` fields from per-frame accumulators (schema v2).
    fun finalizeExtras() {
        when (scene) {
            BenchScene.SEMANTICS_BUILD -> if (semNodesSamples > 0) {
                putExtra("nodes_per_frame", (semNodesSum / semNodesSamples).toString())
            }

            BenchScene.APP_SWITCH -> if (switchCycles > 0) {
                putExtra("teardown_ms", fmt1(teardownSumMs / switchCycles))
                putExtra("resume_ms", fmt1(resumeSumMs / switchCycles))
                putExtra("switch_cycles", switchCycles.toString())
            }

            BenchScene.POINTER_STORM -> putExtra("hit_tests_per_frame", "1000")

            BenchScene.INPUT_LATENCY -> {
                // Missing optional fields serialize as null (spec: the response
                // should always arrive, but don't drop the keys if it didn't).
                if ("latency_frames" !in extras) putExtra("latency_frames", "null")
                if ("latency_ms" !in extras) putExtra("latency_ms", "null")
            }

            else -> {}
        }
    }

    @Composable
    fun Content() {
        when (scene) {
            BenchScene.HELLO -> HelloScene()
            BenchScene.SCROLL_10K -> ScrollScene()
            BenchScene.TEXT_CJK -> TextCjkScene()
            BenchScene.GLASS_BLUR -> GlassBlurScene()
            BenchScene.ANIM_100 -> Anim100Scene()
            BenchScene.GALLERY -> GalleryScene()
            BenchScene.RESIZE -> ResizeScene()
            BenchScene.INPUT_IME -> InputImeScene()
            BenchScene.VIDEO_PLAYBACK -> VideoPlaybackScene()

            // --- schema-v2 families ---
            BenchScene.LIST_CREATE_1K, BenchScene.LIST_REPLACE_1K, BenchScene.LIST_UPDATE_10TH,
            BenchScene.LIST_SWAP_ROWS, BenchScene.LIST_REMOVE_ROW, BenchScene.LIST_CLEAR_1K,
            -> ListOpsContent()

            BenchScene.SHAPES_RAMP, BenchScene.PATHS_RAMP, BenchScene.TEXT_RAMP,
            BenchScene.IMAGES_RAMP,
            -> RampContent()

            BenchScene.OVERDRAW_STACK, BenchScene.ELEVATION_GRID, BenchScene.RELAYOUT_STORM,
            BenchScene.MOUNT_CHURN, BenchScene.SCROLL_ANIM, BenchScene.TEXT_RICH,
            BenchScene.CHART_LIVE, BenchScene.CLIP_PATH, BenchScene.THEME_SWITCH,
            BenchScene.BACKDROP_SCROLL,
            -> StressContent()

            BenchScene.INPUT_LATENCY, BenchScene.POINTER_STORM, BenchScene.SEMANTICS_BUILD,
            BenchScene.APP_SWITCH,
            -> SystemContent()
        }
    }

    // --- scene: hello — a simple centered text widget ---

    @Composable
    private fun HelloScene() {
        // Klaxon: center { text "Hello, Klaxon!" 24px white }.
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("Hello, Klaxon!", fontSize = 24.sp, color = Color.White)
        }
    }

    // --- scene: scroll_10k — a virtualized list of 10 000 items ---

    @Composable
    private fun ScrollScene() {
        // Klaxon: column(pad 16, gap 12) [ title 14 #CCCCCC, box(max 880x300)
        // [ listView 10_000 x 36px ] ]. LazyColumn virtualizes natively — only
        // the rows intersecting the viewport are composed, like Klaxon's
        // syncItemWindow.
        val state = rememberLazyListState()
        listState = state // publish for the tick
        Column(
            Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "scroll_10k — 10 000 items, virtualized (~10 live nodes)",
                fontSize = 14.sp, color = Color(0xFFCCCCCC)
            )
            Box(Modifier.fillMaxWidth().height(300.dp)) {
                LazyColumn(state = state, modifier = Modifier.fillMaxSize()) {
                    items(10_000, key = { it }) { index ->
                        BenchListRow(index, height = 36.dp)
                    }
                }
            }
        }
    }

    // --- scene: text_cjk — Chinese / Japanese / Korean text (shaping stress) ---

    @Composable
    private fun TextCjkScene() {
        // Klaxon: column(pad 24, gap 10) of 5 texts (14/22/22/22/18) — same
        // strings. Skiko shapes via CoreText with system fallback fonts
        // (PingFang for CJK, Apple Color Emoji for emoji) — see README.
        Column(
            Modifier.fillMaxSize().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                "text_cjk — CJK shaping (中文 / 日本語 / 한국어)",
                fontSize = 14.sp, color = Color(0xFFCCCCCC)
            )
            Text("你好，世界！Klaxon 是一个用 Zig 编写的 UI 框架。", fontSize = 22.sp, color = Color.White)
            Text(
                "こんにちは、世界！Klaxon は Zig で書かれた UI フレームワークです。",
                fontSize = 22.sp, color = Color.White
            )
            Text(
                "안녕하세요, 세계! Klaxon은 Zig로 작성된 UI 프레임워크입니다.",
                fontSize = 22.sp, color = Color.White
            )
            Text("混ぜるな危険 — CJK + Latin + emoji 🌍🎉", fontSize = 18.sp, color = Color(0xFFFFD54F))
        }
    }

    // --- scene: glass_blur — translucent cards over a colorful backdrop ---

    @Composable
    private fun GlassBlurScene() {
        // Klaxon: backdrop #101426 [ stack [ deco column: 3 panels (#E91E63 /
        // #3F51B5 / #00ACC1, 150px, r12); 3 glass cards 300x110 r16 at
        // center / top-right / bottom-left ] ]. The card is an alpha layer
        // (0.45) + tint rounded rect + 3 white bars (alpha 1 / .7 / .5).
        // NOTE: like Klaxon (and the Qt port), NEITHER side does a real
        // backdrop blur — the alpha layer is the documented stand-in (the
        // kx_skia ABI has no blur primitive); Compose replicates it with
        // Modifier.alpha(0.45f).
        Box(Modifier.fillMaxSize().background(Color(0xFF101426))) {
            Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFFE91E63)))
                Box(Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF3F51B5)))
                Box(Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFF00ACC1)))
            }
            GlassCard(Modifier.align(Alignment.Center), Color.White)
            GlassCard(Modifier.align(Alignment.TopEnd), Color(0xFFFFD54F))
            GlassCard(Modifier.align(Alignment.BottomStart), Color(0xFF80FF87))
        }
    }

    // --- scene: anim_100 — 100 widgets with concurrent animations ---

    @Composable
    private fun Anim100Scene() {
        // Klaxon: grid(10 cols, gap 8, pad 16) of 100 animated containers; the
        // tick retargets height + color every frame -> a relayout + repaint of
        // all 100.
        SimpleGrid(Modifier.fillMaxSize(), columns = 10, hGap = 8.dp, vGap = 8.dp, padding = 16.dp) {
            for (i in 0 until ANIM_WIDGETS) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(heights[i].value.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(Color(colors[i].value)),
                )
            }
        }
    }

    // --- scene: gallery — a representative multi-widget page ---

    @Composable
    private fun GalleryScene() {
        // A REPRESENTATIVE subset of Klaxon's gallery app (gallery.zig: header
        // + a scroll view over 32 sections, 696 visible nodes). This port
        // composes 24 varied widget cards in a plain Column — all live,
        // overflow clipped, like Klaxon's non-virtualized scroll view. See
        // README: not timing-comparable.
        Column(
            Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("gallery — representative widget showcase (Compose port)", fontSize = 18.sp, color = Color.White)
            Text(
                "a subset of Klaxon's 32-section gallery — see bench/runners/compose/README.md",
                fontSize = 14.sp, color = Color(0xFFCCCCCC)
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = {}, label = { Text("chip") })
                AssistChip(onClick = {}, label = { Text("chip") })
            }
            for (i in 0 until 24) GalleryCard(i)
        }
    }

    // --- scene: resize — a widget tree that handles resize events ---

    @Composable
    private fun ResizeScene() {
        // Klaxon: column(pad 16, gap 12) [ title, row of 3 cards (#2A2A3E r8
        // pad 12 "Card" 13), box(max 880x200) [ listView 2_000 x 32px ] ]. The
        // tick cycles RESIZE_SIZES: the scene + surface are resized and the
        // tree relayouts.
        Column(
            Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "resize — the viewport cycles every frame (layout stress)",
                fontSize = 14.sp, color = Color(0xFFCCCCCC)
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                for (i in 0 until 3) {
                    Card(
                        shape = RoundedCornerShape(8.dp),
                        colors = CardDefaults.cardColors(containerColor = Color(0xFF2A2A3E)),
                    ) {
                        Text(
                            "Card",
                            modifier = Modifier.padding(12.dp),
                            fontSize = 13.sp, color = Color.White
                        )
                    }
                }
            }
            Box(Modifier.fillMaxWidth().height(200.dp)) {
                LazyColumn(modifier = Modifier.fillMaxSize()) {
                    items(2_000, key = { it }) { index ->
                        BenchListRow(index, height = 32.dp)
                    }
                }
            }
        }
    }

    // --- scene: input_ime — a text field with input handling ---

    @Composable
    private fun InputImeScene() {
        // Klaxon: column(pad 24, gap 12) [ title, filled text field (label
        // "Message", placeholder "こんにちは…", supporting text, light theme) ].
        // The tick feeds IME text_input commits (CJK + emoji) with a backspace
        // every 12th frame. NOTE: no real keyboard/IME — the value is driven
        // programmatically (the headless analog of text_input commits; see
        // README).
        Column(
            Modifier.fillMaxSize().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "input_ime — text field, IME text_input commits (CJK + emoji)",
                fontSize = 14.sp, color = Color(0xFFCCCCCC)
            )
            TextField(
                value = text,
                onValueChange = {}, // driven programmatically by the tick
                label = { Text("Message") },
                placeholder = { Text("こんにちは…") },
                supportingText = { Text("type CJK / emoji — the buffer follows the caret") },
                singleLine = false,
                modifier = Modifier.fillMaxWidth(),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color(0xFFF2F2F7),
                    unfocusedContainerColor = Color(0xFFF2F2F7),
                    focusedTextColor = Color(0xFF1C1B1F),
                    unfocusedTextColor = Color(0xFF1C1B1F),
                    focusedLabelColor = Color(0xFF6750A4),
                    unfocusedLabelColor = Color(0xFF49454F),
                    focusedPlaceholderColor = Color(0xFF49454F),
                    unfocusedPlaceholderColor = Color(0xFF49454F),
                    focusedSupportingTextColor = Color(0xFF49454F),
                    unfocusedSupportingTextColor = Color(0xFF49454F),
                    focusedIndicatorColor = Color(0xFF6750A4),
                    unfocusedIndicatorColor = Color.Transparent,
                ),
            )
        }
    }

    // --- scene: video_playback — a widget that updates a texture every frame ---

    @Composable
    private fun VideoPlaybackScene() {
        // Klaxon: column(pad 16, gap 12) [ title, video widget 320x180 ]. Every
        // paint regenerates the frame's pixels (an x/y gradient + a 24px white
        // bar sliding 3px/frame) and uploads a FRESH texture. The Compose port
        // regenerates the same pixel buffer in the Canvas draw lambda and
        // uploads it through a fresh Skiko bitmap every frame.
        Column(
            Modifier.fillMaxSize().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "video_playback — simulated 320×180 stream (texture re-upload every frame)",
                fontSize = 14.sp, color = Color(0xFFCCCCCC)
            )
            VideoCanvas(Modifier.size(320.dp, 180.dp), videoFrame)
        }
    }

    @Composable
    private fun VideoCanvas(modifier: Modifier, frame: Long) {
        val pixels = remember { ByteArray(VIDEO_W * VIDEO_H * 4) }
        val imageInfo = remember { ImageInfo.makeN32(VIDEO_W, VIDEO_H, ColorAlphaType.PREMUL) }
        Canvas(modifier) {
            // Klaxon's per-pixel loop (bench.zig videoPaint), in N32 memory
            // order (B,G,R,A on macOS): r = x*255/(w-1), g = y*255/(h-1),
            // b = 0x60, plus a white bar at (frame*3) mod w, 24px wide.
            val bar = ((frame * 3) % VIDEO_W).toInt()
            var i = 0
            for (y in 0 until VIDEO_H) {
                val g = (y * 255 / (VIDEO_H - 1)).toByte()
                for (x in 0 until VIDEO_W) {
                    val r = (x * 255 / (VIDEO_W - 1)).toByte()
                    pixels[i] = 0x60              // B
                    pixels[i + 1] = g             // G
                    pixels[i + 2] = r             // R
                    pixels[i + 3] = 0xFF.toByte() // A
                    if (x >= bar && x < bar + 24) {
                        pixels[i] = 0xFF.toByte()
                        pixels[i + 1] = 0xFF.toByte()
                        pixels[i + 2] = 0xFF.toByte()
                    }
                    i += 4
                }
            }
            // The "texture upload": a fresh bitmap per frame (Klaxon:
            // kx_image_create copies the pixels; create + draw + destroy per
            // frame).
            Bitmap().use { bitmap ->
                bitmap.installPixels(imageInfo, pixels, VIDEO_W * 4)
                drawImage(bitmap.asComposeImageBitmap())
            }
        }
    }
}

/// One list row — the bench.zig benchListItem structure: a #2A2A3E card
/// (r6, padding 8/6) with a row (gap 8, centered) of a 14px star + "Item #N".
@Composable
internal fun BenchListRow(index: Int, height: Dp) {
    Card(
        modifier = Modifier.fillMaxWidth().height(height),
        shape = RoundedCornerShape(6.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF2A2A3E)),
    ) {
        Row(
            modifier = Modifier.fillMaxSize().padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            StarIcon(Modifier.size(14.dp))
            Text("Item #$index", fontSize = 14.sp, color = Color.White)
        }
    }
}

/// A 14px five-point star (Klaxon's icon.star analog) drawn as a vector path.
@Composable
internal fun StarIcon(modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val path = Path()
        val cx = size.width / 2
        val cy = size.height / 2
        val rOuter = size.minDimension / 2
        val rInner = rOuter * 0.4f
        for (i in 0 until 10) {
            val angle = (-Math.PI / 2 + i * Math.PI / 5).toFloat()
            val r = if (i % 2 == 0) rOuter else rInner
            val x = cx + r * cos(angle)
            val y = cy + r * sin(angle)
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        drawPath(path, Color(0xFFFFD54F))
    }
}

@Composable
private fun GlassCard(modifier: Modifier, tint: Color) {
    Box(
        modifier
            .size(300.dp, 110.dp)
            .alpha(0.45f)
            .clip(RoundedCornerShape(16.dp))
            .background(tint)
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.fillMaxWidth().height(6.dp).background(Color.White))
            Box(Modifier.fillMaxWidth(0.62f).height(6.dp).background(Color.White.copy(alpha = 0.7f)))
            Box(Modifier.fillMaxWidth(0.4f).height(6.dp).background(Color.White.copy(alpha = 0.5f)))
        }
    }
}

/// A fixed grid: ONE layout node for the grid + one per child (Klaxon's
/// widgets.layout.grid is not virtualized — all children are live, and so is
/// this port; a LazyVerticalGrid would virtualize the overflow rows away).
@Composable
internal fun SimpleGrid(
    modifier: Modifier = Modifier,
    columns: Int,
    hGap: Dp,
    vGap: Dp,
    padding: Dp = 0.dp,
    content: @Composable () -> Unit,
) {
    Layout(content = content, modifier = modifier.padding(padding)) { measurables, constraints ->
        val hGapPx = (hGap.value * density).roundToInt()
        val vGapPx = (vGap.value * density).roundToInt()
        val rows = (measurables.size + columns - 1) / columns
        val cellW = (constraints.maxWidth - hGapPx * (columns - 1)) / columns
        val placeables = measurables.map { it.measure(Constraints(maxWidth = cellW, maxHeight = constraints.maxHeight)) }
        val cellH = placeables.maxOfOrNull { it.height } ?: 0
        val width = (cellW * columns + hGapPx * (columns - 1))
            .coerceIn(constraints.minWidth, constraints.maxWidth)
        val height = (cellH * rows + vGapPx * (rows - 1).coerceAtLeast(0))
            .coerceIn(constraints.minHeight, constraints.maxHeight)
        layout(width, height) {
            placeables.forEachIndexed { index, placeable ->
                placeable.placeRelative(
                    x = (index % columns) * (cellW + hGapPx),
                    y = (index / columns) * (cellH + vGapPx),
                )
            }
        }
    }
}

@Composable
private fun GalleryCard(i: Int) {
    Card(
        Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        colors = CardDefaults.cardColors(containerColor = Color(0xFF2A2A3E)),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            when (i % 8) {
                0 -> OutlinedButton(onClick = {}) { Text("Button $i") }

                1 -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Switch(checked = i % 2 == 0, onCheckedChange = null)
                    Text("Switch $i", color = Color.White, fontSize = 14.sp)
                }

                2 -> Slider(value = 0.3f, onValueChange = {}, enabled = false)

                3 -> LinearProgressIndicator(progress = { 0.4f }, modifier = Modifier.fillMaxWidth())

                4 -> TextField(
                    value = "field $i",
                    onValueChange = {},
                    label = { Text("Label") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )

                5 -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Checkbox(checked = i % 2 == 0, onCheckedChange = null)
                    Text("Checkbox $i", color = Color.White, fontSize = 14.sp)
                }

                6 -> {
                    Text(
                        "Card $i — body text with CJK 你好 and emoji 🌍",
                        fontSize = 14.sp, color = Color(0xFFCCCCCC)
                    )
                    Text("caption", fontSize = 12.sp, color = Color(0xFF888899))
                }

                7 -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    StarIcon(Modifier.size(16.dp))
                    Text("List item $i", color = Color.White, fontSize = 14.sp)
                    Spacer(Modifier.weight(1f))
                    Badge { Text("$i") }
                }
            }
        }
    }
}
