// ScenesStress.kt — Family C of the schema-v2 catalogue (bench-scenes.md):
// the ten known-divergence stress scenes, over the standard 10 warmup + 120
// measured frame contract.
//
// Animated quantities read state.animFrame inside offset{} / graphicsLayer{} /
// drawBehind{} / Modifier.layout lambdas — placement-, draw- or layout-phase
// reads, so the per-frame animation pays exactly the phase the spec targets
// (relayout_storm deliberately reads in the MEASURE phase instead).

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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.GenericShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.runBlocking
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/** chart_live: the line chart's point count. */
const val CHART_POINTS = 1_000

/** mount_churn: the steady-state widget pool (50 destroyed + 50 created per frame). */
const val CHURN_POOL_SIZE = 500

private val GRID_LINE = Color(0xFF2A2A3E)
private val AXIS_LINE = Color(0xFF888899)
private val SHADOW_COLOR = Color(0f, 0f, 0f, 0.30f)

internal fun SceneState.tickStress(frame: Long, harness: Harness) {
    animFrame.longValue = frame // the shared animation clock for this family
    when (scene) {
        BenchScene.MOUNT_CHURN -> {
            // Destroy 50 widgets, create 50 new ones (deterministic LCG picks
            // the victims), steady-state pool 500.
            repeat(CHURN_PER_FRAME) { churnPool.removeAt(nextChurnIndex(churnPool.size)) }
            repeat(CHURN_PER_FRAME) { churnPool += churnNextId++ }
        }

        BenchScene.SCROLL_ANIM -> {
            // 600 dp/s at the 60 fps cadence = 10 dp/frame (the loop is
            // unpaced; the per-frame advance is the frame-time-equivalent).
            if (frame > 0) {
                val maxOff = 10_000 * 36 - HEIGHT
                val off = (frame * 10) % (maxOff + 1)
                runBlocking { listState!!.scrollToItem((off / 36).toInt(), (off % 36).toInt()) }
            }
        }

        BenchScene.CHART_LIVE -> {
            // Slide the window one point left and append the next sample: the
            // "live data" that forces the full polyline rebuild at paint.
            chartData.copyInto(chartData, destinationOffset = 0, startIndex = 1)
            chartData[CHART_POINTS - 1] = nextChartSample()
        }

        BenchScene.THEME_SWITCH -> if (frame > 0 && frame % 30 == 0L) {
            themePalette = if (themePalette == DARK_PALETTE) LIGHT_PALETTE else DARK_PALETTE
        }

        BenchScene.BACKDROP_SCROLL -> {
            if (frame > 0) {
                // 5 dp/frame steady scroll; both lists (content + the blurred
                // band copy) get the same offset so the band tracks.
                val maxOff = 200 * 48 - HEIGHT
                val off = (frame * 5) % (maxOff + 1)
                runBlocking {
                    listState!!.scrollToItem((off / 48).toInt(), (off % 48).toInt())
                    listState2!!.scrollToItem((off / 48).toInt(), (off % 48).toInt())
                }
            }
        }

        else -> {}
    }
}

private const val CHURN_PER_FRAME = 50

private fun SceneState.nextChurnIndex(max: Int): Int {
    lcg = lcg * 6364136223846793005L + 1442695040888963407L
    return ((lcg ushr 33) % max).toInt()
}

internal fun SceneState.initChart() {
    repeat(CHART_POINTS) { chartData[it] = nextChartSample() }
}

/// The chart's deterministic series: two sines + an LCG noise term, in the
/// viewport's y-range (0..480, higher = lower on screen).
private fun SceneState.nextChartSample(): Double {
    lcg = lcg * 6364136223846793005L + 1442695040888963407L
    val noise = ((lcg ushr 33) % 41).toDouble() - 20.0
    val t = chartPhase++.toDouble()
    return 240.0 + 180.0 * sin(t * 0.05) + 60.0 * sin(t * 0.37) + noise
}

@Composable
internal fun SceneState.StressContent() {
    when (scene) {
        BenchScene.OVERDRAW_STACK -> OverdrawStackScene()
        BenchScene.ELEVATION_GRID -> ElevationGridScene()
        BenchScene.RELAYOUT_STORM -> RelayoutStormScene()
        BenchScene.MOUNT_CHURN -> MountChurnScene()
        BenchScene.SCROLL_ANIM -> ScrollAnimScene()
        BenchScene.TEXT_RICH -> TextRichScene()
        BenchScene.CHART_LIVE -> ChartLiveScene()
        BenchScene.CLIP_PATH -> ClipPathScene()
        BenchScene.THEME_SWITCH -> ThemeSwitchScene()
        BenchScene.BACKDROP_SCROLL -> BackdropScrollScene()
        else -> {}
    }
}

// --- overdraw_stack: 24 full-screen alpha rects, alternating colors ---

@Composable
private fun OverdrawStackScene() {
    // Each rect: alpha=0x1F (31/255) over the last — Modifier.alpha forces a
    // compositing layer per rect (the spec's saveLayer/compositing cost).
    // Static: the cost is in paint, not animation.
    Box(Modifier.fillMaxSize()) {
        repeat(24) { i ->
            Box(
                Modifier
                    .fillMaxSize()
                    .alpha(31f / 255f)
                    .background(if (i % 2 == 0) PURPLE else TEAL),
            )
        }
    }
}

// --- elevation_grid: 10x10 cards, M3-elevation-style shadow, fill oscillating ---

@Composable
private fun SceneState.ElevationGridScene() {
    // 10x10 grid of 48x40 cards; shadow r=12, blur=6, rgba(0,0,0,0.30). The
    // stock Compose idiom is Modifier.shadow(elevation, shape, ambient, spot):
    // elevation 6.dp stands in for blur=6 and the spec's dy=2 has no separate
    // control (the shadow's offset derives from elevation) — see README.
    SimpleGrid(Modifier.fillMaxSize(), columns = 10, hGap = 6.dp, vGap = 6.dp, padding = 8.dp) {
        repeat(100) { i ->
            Box(
                Modifier
                    .size(48.dp, 40.dp)
                    .shadow(elevationDp(i).dp, RoundedCornerShape(12.dp), clip = false, ambientColor = SHADOW_COLOR, spotColor = SHADOW_COLOR)
                    .drawBehind {
                        drawRoundRect(color = elevationFill(i), cornerRadius = CornerRadius(12.dp.toPx()))
                    },
            )
        }
    }
}

/// Card fill oscillating +-4% lightness per frame (base #2A2A3E): the draw-
/// phase read re-rasterizes fill AND shadow every frame without recomposing.
private fun SceneState.elevationFill(i: Int): Color {
    val k = 1f + 0.04f * sin(animFrame.longValue * 0.1 + i * 0.31).toFloat()
    return Color(0x2A / 255f * k, 0x2A / 255f * k, 0x3E / 255f * k)
}

/// The shadow's raster input must change every frame too — a static 6.dp
/// elevation would leave the shadow cached while only the fill repaints
/// (the spec wants all 100 card shadows re-rasterized per frame).
/// Oscillates 4..8 dp on the same per-card phase as elevationFill.
private fun SceneState.elevationDp(i: Int): Float =
    6f + 2f * sin(animFrame.longValue * 0.1 + i * 0.31).toFloat()

// --- relayout_storm: 200 rows animating width 200<->440 dp (2 s loop) ---

@Composable
private fun SceneState.RelayoutStormScene() {
    // The width is read inside Modifier.layout — a MEASURE-phase read, so every
    // frame pays measure+layout of the subtree (explicitly NOT a compositable
    // transform: graphicsLayer would only re-place).
    Column(Modifier.fillMaxSize()) {
        repeat(200) { i ->
            Box(
                Modifier
                    .height(2.dp)
                    .layout { measurable, constraints ->
                        val w = (320.0 + 120.0 * sin(animFrame.longValue * (2 * PI / 120) + i * 0.15))
                            .roundToInt()
                            .coerceIn(1, constraints.maxWidth)
                        val p = measurable.measure(Constraints.fixed(w, constraints.maxHeight))
                        layout(w, p.height) { p.place(0, 0) }
                    }
                    .background(if (i % 2 == 0) PURPLE else TEAL),
            )
        }
    }
}

// --- mount_churn: 50 widgets out / 50 in per frame, pool 500 ---

@Composable
private fun SceneState.MountChurnScene() {
    // A non-virtualized Column keeps all 500 pool entries live (overflow
    // clipped); key() tracks identity so removals dispose and additions
    // compose — the GC/allocator pressure test.
    Column(Modifier.fillMaxSize()) {
        churnPool.forEach { id ->
            key(id) {
                Row(
                    Modifier.fillMaxWidth().height(16.dp).padding(horizontal = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    StarIcon(Modifier.size(12.dp))
                    Text("Card #$id", fontSize = 11.sp, color = Color.White, maxLines = 1)
                }
            }
        }
    }
}

// --- scroll_anim: 10k list at 600 dp/s + pulsing row icons ---

@Composable
private fun SceneState.ScrollAnimScene() {
    // The scroll_10k list scrolling at 600 dp/s while row icons pulse opacity.
    // Closest-idiom note (README): the spec's "30 embedded row icons" is
    // approximated as 2 pulsing icons per row — LazyColumn only composes the
    // ~14-row live window, so ~28 icons pulse per frame.
    val state = rememberLazyListState()
    listState = state
    LazyColumn(state = state, modifier = Modifier.fillMaxSize()) {
        items(10_000, key = { it }) { index ->
            Row(
                Modifier.fillMaxWidth().height(36.dp).padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                StarIcon(Modifier.size(12.dp).graphicsLayer { alpha = pulseAlpha() })
                StarIcon(Modifier.size(12.dp).graphicsLayer { alpha = pulseAlpha() })
                Text("Item #$index", fontSize = 14.sp, color = Color.White, maxLines = 1)
            }
        }
    }
}

private fun SceneState.pulseAlpha() = (0.5f + 0.5f * sin(animFrame.longValue * 0.2).toFloat())

// --- text_rich: 60 paragraphs x 3 lines of mixed spans + bidi ---

@Composable
private fun TextRichScene() {
    // 60 paragraphs x 3 lines: mixed bold/italic spans at 12sp, one LTR+RTL
    // bidi line at 16sp, a 20sp body line. Non-virtualized (all 180 texts are
    // live; overflow clips) — shaping stress. Static content: Skiko caches
    // shaped runs, so steady-state cost is the full text repaint (see README).
    Column(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
        repeat(60) { p ->
            Text(
                buildAnnotatedString {
                    append("Para $p: ")
                    withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append("bold claim ") }
                    withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append("italic aside ") }
                    append("— body text 0123456789")
                },
                fontSize = 12.sp,
                color = Color.White,
                maxLines = 1,
            )
            Text(
                "مختصر Klaxon عربي test اختبار",
                fontSize = 16.sp,
                color = Color(0xFFCCCCCC),
                maxLines = 1,
            )
            Text(
                "The quick brown fox jumps over the lazy dog — line $p",
                fontSize = 20.sp,
                color = Color.White,
                maxLines = 1,
            )
        }
    }
}

// --- chart_live: 1000-point polyline fully rebuilt per frame + 10x8 grid ---

@Composable
private fun SceneState.ChartLiveScene() {
    Canvas(Modifier.fillMaxSize()) {
        animFrame.longValue // draw-phase read: one repaint per frame
        val w = size.width
        val h = size.height
        // axes + 10x8 grid
        for (g in 1..10) {
            val x = w * g / 11f
            drawLine(GRID_LINE, Offset(x, 0f), Offset(x, h), strokeWidth = 1f)
        }
        for (g in 1..8) {
            val y = h * g / 9f
            drawLine(GRID_LINE, Offset(0f, y), Offset(w, y), strokeWidth = 1f)
        }
        drawRect(AXIS_LINE, style = Stroke(width = 2f))
        // the polyline is rebuilt fully every frame (the dashboard case)
        val path = Path()
        for (i in 0 until CHART_POINTS) {
            val x = i * w / (CHART_POINTS - 1)
            val y = chartData[i].toFloat().coerceIn(0f, h)
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, TEAL, style = Stroke(width = 2f, cap = StrokeCap.Round))
    }
}

// --- clip_path: 120 nodes clipped by a 6-point star, contents scrolling ---

@Composable
private fun SceneState.ClipPathScene() {
    val star = remember {
        GenericShape { size, _ ->
            // 6-point star = 12 vertices alternating outer/inner radius.
            val cx = size.width / 2
            val cy = size.height / 2
            val rOuter = size.minDimension / 2
            val rInner = rOuter * 0.45f
            for (k in 0 until 12) {
                val a = -PI / 2 + k * PI / 6
                val r = if (k % 2 == 0) rOuter else rInner
                val x = cx + r * cos(a).toFloat()
                val y = cy + r * sin(a).toFloat()
                if (k == 0) moveTo(x, y) else lineTo(x, y)
            }
            close()
        }
    }
    SimpleGrid(Modifier.fillMaxSize(), columns = 10, hGap = 8.dp, vGap = 8.dp, padding = 8.dp) {
        repeat(120) {
            Box(Modifier.size(56.dp, 32.dp).clip(star)) {
                // Contents scrolling under the clip: two 32dp color bands
                // cycling upward (placement-phase offset read).
                Column(
                    Modifier
                        .fillMaxWidth()
                        .height(64.dp)
                        .offset { IntOffset(0, -((animFrame.longValue * 2) % 32).toInt()) },
                ) {
                    Box(Modifier.fillMaxWidth().height(32.dp).background(PURPLE))
                    Box(Modifier.fillMaxWidth().height(32.dp).background(TEAL))
                }
            }
        }
    }
}

// --- theme_switch: 200+-node gallery-like tree, light/dark every 30 frames ---

data class ThemePalette(
    val bg: Color,
    val surface: Color,
    val text: Color,
    val dim: Color,
    val accent: Color,
)

val DARK_PALETTE = ThemePalette(
    bg = Color(0xFF14141C), surface = Color(0xFF2A2A3E), text = Color.White,
    dim = Color(0xFF888899), accent = PURPLE,
)
val LIGHT_PALETTE = ThemePalette(
    bg = Color(0xFFF6F6FA), surface = Color(0xFFFFFFFF), text = Color(0xFF1C1B1F),
    dim = Color(0xFF5F5E66), accent = PURPLE,
)

@Composable
private fun SceneState.ThemeSwitchScene() {
    // Every color below is read from themePalette during composition, so a
    // toggle recomposes + repaints the whole tree — the spec's global
    // invalidation cost. ~40 cards x ~9 nodes = ~365 layout nodes.
    val theme = themePalette
    Column(
        Modifier.fillMaxSize().background(theme.bg).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("theme_switch — global invalidation every 30 frames", fontSize = 14.sp, color = theme.text)
        repeat(40) { i -> ThemeSwitchCard(i, theme) }
    }
}

@Composable
private fun ThemeSwitchCard(i: Int, theme: ThemePalette) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(theme.surface),
    ) {
        Row(
            Modifier.fillMaxSize().padding(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(Modifier.size(24.dp).clip(RoundedCornerShape(4.dp)).background(theme.accent))
            Column {
                Text("Card $i — gallery widget", fontSize = 14.sp, color = theme.text, maxLines = 1)
                Text("supporting text", fontSize = 11.sp, color = theme.dim, maxLines = 1)
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(28.dp, 18.dp).clip(RoundedCornerShape(9.dp)).background(theme.accent)) {
                Text("$i", fontSize = 10.sp, color = Color.White, modifier = Modifier.align(Alignment.Center))
            }
        }
    }
}

// --- backdrop_scroll: 200 items under a blurred 640x160 band + 60% scrim ---

@Composable
private fun SceneState.BackdropScrollScene() {
    // Closest-idiom backdrop blur (see README): stock Compose has no
    // backdrop-blur modifier, so a SECOND, non-scrollable copy of the list
    // sits inside the 160dp band, scrolled in lockstep by the tick and
    // blurred with Modifier.blur(12.dp) (sigma ~= radius px at density 1).
    // The 60% scrim rides on top.
    val scroller = rememberLazyListState()
    val band = rememberLazyListState()
    listState = scroller
    listState2 = band
    Box(Modifier.fillMaxSize()) {
        LazyColumn(state = scroller, modifier = Modifier.fillMaxSize()) {
            items(200, key = { it }) { index -> BenchListRow(index, height = 48.dp) }
        }
        Box(
            Modifier
                .fillMaxWidth()
                .height(160.dp)
                .align(Alignment.TopCenter)
                .clipToBounds(),
        ) {
            LazyColumn(
                state = band,
                userScrollEnabled = false,
                modifier = Modifier.fillMaxSize().blur(12.dp),
            ) {
                items(200, key = { it }) { index -> BenchListRow(index, height = 48.dp) }
            }
            Box(Modifier.fillMaxSize().background(Color(0f, 0f, 0f, 0.6f)))
        }
    }
}
