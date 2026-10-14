// Scenes.kt — the scene subset ported from the desktop runner
// (bench/runners/compose/.../Scenes.kt) to Jetpack Compose on Android:
// hello, scroll_10k, anim_100, input_ime + the SceneState/tick machinery.
//
// The schema-v2 catalogue scenes live in ScenesRamp.kt (Family B) and
// ScenesStress.kt (Family C subset). Scene structure, strings, sizes, colors
// and tick cadence mirror the desktop port (and bench.zig) as closely as
// Compose allows — LocalDensity is forced to 1.0 at the root so Klaxon's raw
// pixel units map 1:1 to dp/sp (Klaxon has no density scaling; the full-panel
// surface matches the tier-2 Android Klaxon run).

package bench.compose

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.runBlocking
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

/** input_ime: the IME commit strings (bench.zig IME_STRINGS). */
val IME_STRINGS = listOf("こんにちは", "世界", "안녕하세요", "你好，世界", "🌍 ", "🎉 ")

// anim_100 colors, as ARGB ints (Klaxon packs colors 0xRRGGBBAA; Compose Color
// takes 0xAARRGGBB — same channels). Klaxon: lerpColor(0x3F51B5FF, 0xE91E63FF, t).
private val INDIGO = 0xFF3F51B5.toInt()
private val PINK = 0xFFE91E63.toInt()

/// Klaxon's closed-form spring (src/ui/anim.zig Spring{stiffness=380,
/// damping=32, mass=1}), retargeted every frame with v0 = 0 and advanced
/// t = 8 ms per frame. Underdamped (zeta = 32 / (2*sqrt(380)) ~ 0.82), so one
/// frame multiplies the displacement by the factor k below.
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
/// tick() invalidates the affected scopes; the recompose lands in the next
/// frame's animation phase and the traversal in the same vsync — the frame's
/// FrameMetrics pick the work up (see Bench.kt's timing notes).
class SceneState(val scene: BenchScene) {
    /** scroll_10k: published from composition via rememberLazyListState. */
    var listState: LazyListState? = null

    // --- anim_100: 100 widgets x (height + color) spring lanes ---
    val heights = Array(ANIM_WIDGETS) { mutableStateOf(32f) }
    val colors = Array(ANIM_WIDGETS) { mutableIntStateOf(INDIGO) }

    // --- input_ime ---
    var text by mutableStateOf("")

    /** The rendered frame index — the shared animation clock every ramp/stress
     *  scene derives positions/phase from. Written once per tick. */
    val animFrame = mutableLongStateOf(0L)

    /** ramp: the current step's item count (set by the tick per step). */
    val rampItemCount = mutableIntStateOf(0)

    // --- mount_churn ---
    val churnPool = mutableStateListOf<Long>()
    var churnNextId = 0L

    /** Shared deterministic LCG for the stress family (churn victims). */
    var lcg = 0x2B992DD5L

    init {
        when (scene) {
            BenchScene.MOUNT_CHURN -> repeat(CHURN_POOL_SIZE) { churnPool += churnNextId++ }
            else -> {}
        }
        if (scene.kind == SceneKind.RAMP) rampItemCount.intValue = RAMP_STEPS[0]
    }

    /// Per-frame scene logic, before recomposition + layout + draw.
    /// Deterministic in `frame` (bench.zig SceneRunner.tick).
    fun tick(frame: Long) {
        when (scene) {
            BenchScene.HELLO -> {
                // static tree — the heartbeat write forces the draw anyway
            }

            BenchScene.SCROLL_10K -> {
                // Klaxon: off = (frame*37) mod (maxScroll+1); item height 36,
                // viewport 300 -> maxScroll = 10_000*36 - 300. Frame 0 targets
                // offset 0 (a no-op) and may run before the first layout,
                // which LazyListState.scrollToItem would wait for.
                val ls = listState
                if (frame > 0 && ls != null) {
                    val maxOff = 10_000 * 36 - 300
                    val off = (frame * 37) % (maxOff + 1)
                    runBlocking { ls.scrollToItem((off / 36).toInt(), (off % 36).toInt()) }
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
                    val c = colors[i].intValue
                    colors[i].intValue =
                        (stepChannel((c shr 24) and 0xFF, (target shr 24) and 0xFF, k) shl 24) or
                            (stepChannel((c shr 16) and 0xFF, (target shr 16) and 0xFF, k) shl 16) or
                            (stepChannel((c shr 8) and 0xFF, (target shr 8) and 0xFF, k) shl 8) or
                            stepChannel(c and 0xFF, target and 0xFF, k)
                }
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

            // --- schema-v2 families (ScenesRamp.kt / ScenesStress.kt) ---

            BenchScene.SHAPES_RAMP, BenchScene.TEXT_RAMP, BenchScene.IMAGES_RAMP ->
                tickRamp(frame)

            BenchScene.ELEVATION_GRID, BenchScene.MOUNT_CHURN ->
                tickStress(frame)
        }
    }

    @Composable
    fun Content() {
        when (scene) {
            BenchScene.HELLO -> HelloScene()
            BenchScene.SCROLL_10K -> ScrollScene()
            BenchScene.ANIM_100 -> Anim100Scene()
            BenchScene.INPUT_IME -> InputImeScene()

            // --- schema-v2 families ---
            BenchScene.SHAPES_RAMP, BenchScene.TEXT_RAMP, BenchScene.IMAGES_RAMP -> RampContent()
            BenchScene.ELEVATION_GRID, BenchScene.MOUNT_CHURN -> StressContent()
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
            // Klaxon's constrainedBox(max 880x300) — on the 640px desktop
            // viewport fillMaxWidth fit inside; the full-panel Android surface
            // (1080px) needs the cap for row-width parity.
            Box(Modifier.widthIn(max = 880.dp).fillMaxWidth().height(300.dp)) {
                LazyColumn(state = state, modifier = Modifier.fillMaxSize()) {
                    items(10_000, key = { it }) { index ->
                        BenchListRow(index, height = 36.dp)
                    }
                }
            }
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
                        .background(Color(colors[i].intValue)),
                )
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
        // programmatically (same approach as the desktop runner).
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
