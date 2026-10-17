// ScenesRamp.kt — Family B of the schema-v2 catalogue (bench-scenes.md):
// MotionMark-style stepped ramps. The harness runs RAMP_STEPS (10 .. 3200):
// per step it sets state.rampItemCount, renders 10 warmup + 20 measured frames
// (one continuous animation clock across steps), and reports the per-step p50
// in extra.ramp[] plus extra.n_max_60fps.
//
// All four scenes place N items in one full-viewport Box; item positions and
// rotations read state.animFrame inside offset{} / graphicsLayer{} lambdas so
// the per-frame animation invalidates placement/draw only (no recomposition —
// the same state-read discipline a real Compose app uses for animated
// positions). The Compose "item" is a layout node each, like Klaxon's widget
// and MotionMark's scene-graph element.

package bench.compose

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asComposeImageBitmap
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.ColorAlphaType
import org.jetbrains.skia.ImageInfo
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// The Lissajous path every translating ramp item follows (spec: "translating
// 4px/frame on a Lissajous path"). x(t) = 300 + 280 sin(t + i*0.61),
// y(t) = 228 + 200 sin(1.4t + i*0.83) with t = frame * 0.015 — peak speed
// ~4.2 px/frame per axis, ~4 px/frame typical. Kept inside the 640x480
// viewport for the item sizes below.
private const val LISSAJOUS_DT = 0.015

internal fun SceneState.tickRamp(frame: Long, harness: Harness) {
    animFrame.longValue = frame
}

@Composable
internal fun SceneState.RampContent() {
    when (scene) {
        BenchScene.SHAPES_RAMP -> ShapesRampScene()
        BenchScene.PATHS_RAMP -> PathsRampScene()
        BenchScene.TEXT_RAMP -> TextRampScene()
        BenchScene.IMAGES_RAMP -> ImagesRampScene()
        else -> {}
    }
}

// --- shapes_ramp: N rounded rects (r=8dp, 40x24, alternating colors) ---

@Composable
private fun SceneState.ShapesRampScene() {
    val n = rampItemCount.intValue
    Canvas(Modifier.fillMaxSize()) {
        val t = animFrame.longValue * LISSAJOUS_DT
        val w = 40.dp.toPx()
        val h = 24.dp.toPx()
        val cr = CornerRadius(8.dp.toPx(), 8.dp.toPx())
        val sz = Size(w, h)
        for (i in 0 until n) {
            val x = (300.0 + 280.0 * sin(t + i * 0.61)).toFloat()
            val y = (228.0 + 200.0 * sin(t * 1.4 + i * 0.83)).toFloat()
            drawRoundRect(
                color = if (i % 2 == 0) PURPLE else TEAL,
                topLeft = Offset(x, y),
                size = sz,
                cornerRadius = cr,
            )
        }
    }
}

// --- paths_ramp: N identical 12-point closed bezier paths, rotating 1deg/frame ---

@Composable
private fun SceneState.PathsRampScene() {
    val n = rampItemCount.intValue
    // "N identical ... paths": one shared Path object, drawn N times — the
    // geometry is built once (the draw cost is per item, like MotionMark).
    val path = remember { gearBezierPath() }
    Canvas(Modifier.fillMaxSize()) {
        val rot = (animFrame.longValue % 360).toFloat()
        for (i in 0 until n) {
            val ox = ((i * 97) % 592).toFloat()
            val oy = ((i * 57) % 432).toFloat()
            withTransform({
                translate(ox, oy)
                rotate(rot, Offset(24f, 24f))
            }) {
                drawPath(path, if (i % 2 == 0) PURPLE else TEAL)
            }
        }
    }
}

/// A 12-anchor closed bezier (a 6-lobe gear: alternating outer/inner radius in
/// a 48x48 box), Catmull-Rom smoothed through the anchors — ~200 tessellation
/// points once Skia flattens it.
private fun gearBezierPath(): Path {
    val cx = 24f
    val cy = 24f
    val px = FloatArray(12)
    val py = FloatArray(12)
    for (k in 0 until 12) {
        val a = k * PI / 6
        val r = if (k % 2 == 0) 20f else 11f
        px[k] = cx + r * cos(a).toFloat()
        py[k] = cy + r * sin(a).toFloat()
    }
    val path = Path()
    path.moveTo(px[0], py[0])
    for (k in 0 until 12) {
        val p0 = k
        val p1 = (k + 1) % 12
        val pm = (k + 11) % 12
        val p2 = (k + 2) % 12
        // Catmull-Rom -> bezier control points (tension 0.5).
        path.cubicTo(
            px[p0] + (px[p1] - px[pm]) / 6f, py[p0] + (py[p1] - py[pm]) / 6f,
            px[p1] - (px[p2] - px[p0]) / 6f, py[p1] - (py[p2] - py[p0]) / 6f,
            px[p1], py[p1],
        )
    }
    path.close()
    return path
}

// --- text_ramp: N x "The quick brown fox 0123456789" at 14sp, x oscillating ---

@Composable
private fun SceneState.TextRampScene() {
    val n = rampItemCount.intValue
    val measurer = rememberTextMeasurer()
    val style = remember { TextStyle(color = Color.White, fontSize = 14.sp) }
    val measured = remember(measurer, style) {
        measurer.measure("The quick brown fox 0123456789", style = style, softWrap = false)
    }
    Canvas(Modifier.fillMaxSize()) {
        val frame = animFrame.longValue
        for (i in 0 until n) {
            val dx = 40.0 * sin(frame * 0.1 + i * 0.5)
            val x = ((i * 53) % 560 + dx).toFloat()
            val y = ((i * 37) % 460).toFloat()
            drawText(measured, topLeft = Offset(x, y))
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
    Canvas(Modifier.fillMaxSize()) {
        val t = animFrame.longValue * LISSAJOUS_DT
        val dstSz = IntSize(48, 48)
        for (i in 0 until n) {
            val x = (300.0 + 280.0 * sin(t + i * 0.61)).roundToInt()
            val y = (228.0 + 200.0 * sin(t * 1.4 + i * 0.83)).roundToInt()
            // 64 -> 48 px = the spec's 0.75x sampling factor.
            drawImage(image, dstOffset = IntOffset(x, y), dstSize = dstSz)
        }
    }
}

/// The shared 64x64 RGBA test image: an 8px #7C4DFF/#03DAC6 checkerboard,
/// built once per run (the same one-shot Skiko bitmap path as video_playback).
private fun makeCheckerboardImage(): ImageBitmap {
    val pixels = ByteArray(64 * 64 * 4)
    var i = 0
    for (y in 0 until 64) {
        for (x in 0 until 64) {
            // N32 memory order on macOS is B,G,R,A (same as video_playback).
            if ((x / 8 + y / 8) % 2 == 0) {
                pixels[i] = 0xFF.toByte(); pixels[i + 1] = 0x4D; pixels[i + 2] = 0x7C // #7C4DFF
            } else {
                pixels[i] = 0xC6.toByte(); pixels[i + 1] = 0xDA.toByte(); pixels[i + 2] = 0x03 // #03DAC6
            }
            pixels[i + 3] = 0xFF.toByte()
            i += 4
        }
    }
    val bitmap = Bitmap()
    bitmap.installPixels(ImageInfo.makeN32(64, 64, ColorAlphaType.PREMUL), pixels, 64 * 4)
    return bitmap.asComposeImageBitmap()
}
