// ScenesRamp.kt — Family B of the schema-v2 catalogue (bench-scenes.md), the
// three ramp scenes in the subset: shapes_ramp, text_ramp, images_ramp.
// MotionMark-style stepped ramp: the harness runs RAMP_STEPS (10 .. 3200),
// 10 warmup + 20 measured frames per step; the tick sets state.rampItemCount
// at each step boundary and animFrame is one continuous clock across steps
// (matching the desktop runner's ramp loop).
//
// All three scenes place N items in one full-viewport Box; item positions read
// state.animFrame inside offset{} lambdas so the per-frame animation
// invalidates placement only (no recomposition — the same state-read
// discipline a real Compose app uses for animated positions).

package bench.compose

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import kotlin.math.sin

// The Lissajous path every translating ramp item follows (spec: "translating
// 4px/frame on a Lissajous path"). x(t) = 300 + 280 sin(t + i*0.61),
// y(t) = 228 + 200 sin(1.4t + i*0.83) with t = frame * 0.015 — the positions
// stay inside the 640x480 logical window even though the panel is bigger
// (Klaxon's ramp node paints the same scattered items over its full surface).
private const val LISSAJOUS_DT = 0.015

internal fun SceneState.tickRamp(frame: Long) {
    val stepLen = RAMP_WARMUP_FRAMES + RAMP_MEASURED_FRAMES
    val step = (frame / stepLen).toInt()
    val phase = (frame % stepLen).toInt()
    if (phase == 0 && step < RAMP_STEPS.size) rampItemCount.intValue = RAMP_STEPS[step]
    animFrame.longValue = frame
}

@Composable
internal fun SceneState.RampContent() {
    when (scene) {
        BenchScene.SHAPES_RAMP -> ShapesRampScene()
        BenchScene.TEXT_RAMP -> TextRampScene()
        BenchScene.IMAGES_RAMP -> ImagesRampScene()
        else -> {}
    }
}

private fun SceneState.lissajousOffset(i: Int): IntOffset {
    val t = animFrame.longValue * LISSAJOUS_DT
    val x = 300.0 + 280.0 * sin(t + i * 0.61)
    val y = 228.0 + 200.0 * sin(t * 1.4 + i * 0.83)
    return IntOffset(x.roundToInt(), y.roundToInt())
}

// --- shapes_ramp: N rounded rects (r=8dp, 40x24, alternating colors) ---

@Composable
private fun SceneState.ShapesRampScene() {
    val n = rampItemCount.intValue
    Box(Modifier.fillMaxSize()) {
        repeat(n) { i ->
            Box(
                Modifier
                    .offset { lissajousOffset(i) }
                    .size(40.dp, 24.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (i % 2 == 0) PURPLE else TEAL),
            )
        }
    }
}

// --- text_ramp: N x "The quick brown fox 0123456789" at 14sp, x oscillating ---

@Composable
private fun SceneState.TextRampScene() {
    val n = rampItemCount.intValue
    Box(Modifier.fillMaxSize()) {
        repeat(n) { i ->
            Text(
                "The quick brown fox 0123456789",
                fontSize = 14.sp,
                color = Color.White,
                softWrap = false,
                modifier = Modifier.offset {
                    val dx = 40.0 * sin(animFrame.longValue * 0.1 + i * 0.5)
                    IntOffset(((i * 53) % 560 + dx).roundToInt(), (i * 37) % 460)
                },
            )
        }
    }
}

// --- images_ramp: N copies of ONE 64x64 RGBA checkerboard, scaled 0.75x, moving ---

@Composable
private fun SceneState.ImagesRampScene() {
    val n = rampItemCount.intValue
    // The image is generated ONCE at startup — inside the first composition,
    // which lands in warmup (spec: decode/startup cost excluded; the measured
    // frames only pay sampling/draw).
    val image = remember { makeCheckerboardImage() }
    Box(Modifier.fillMaxSize()) {
        repeat(n) { i ->
            Box(Modifier.offset { lissajousOffset(i) }.size(48.dp)) {
                Canvas(Modifier.fillMaxSize()) {
                    // 64 -> 48 px = the spec's 0.75x sampling factor.
                    drawImage(image, dstSize = IntSize(48, 48))
                }
            }
        }
    }
}

/// The shared 64x64 RGBA test image: an 8px #7C4DFF/#03DAC6 checkerboard,
/// built once per run (the desktop runner's Skiko bitmap; Android version uses
/// android.graphics.Bitmap + asImageBitmap()).
private fun makeCheckerboardImage(): ImageBitmap {
    val px = IntArray(64 * 64)
    var i = 0
    for (y in 0 until 64) {
        for (x in 0 until 64) {
            px[i++] = if ((x / 8 + y / 8) % 2 == 0) 0xFF7C4DFF.toInt() else 0xFF03DAC6.toInt()
        }
    }
    return android.graphics.Bitmap
        .createBitmap(px, 64, 64, android.graphics.Bitmap.Config.ARGB_8888)
        .asImageBitmap()
}
