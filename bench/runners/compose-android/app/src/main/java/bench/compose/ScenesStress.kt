// ScenesStress.kt — the two Family C stress scenes in the subset:
// elevation_grid + mount_churn, over the standard 10 warmup + 120 measured
// frame contract. Ported from the desktop runner's ScenesStress.kt.
//
// Animated quantities read state.animFrame inside drawBehind{} — draw-phase
// reads, so the per-frame oscillation pays draw only (no recomposition).

package bench.compose

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.sin

/** mount_churn: the steady-state widget pool (50 destroyed + 50 created per frame). */
const val CHURN_POOL_SIZE = 500

private const val CHURN_PER_FRAME = 50

private val SHADOW_COLOR = Color(0f, 0f, 0f, 0.30f)

internal fun SceneState.tickStress(frame: Long) {
    animFrame.longValue = frame // the shared animation clock for this family
    when (scene) {
        BenchScene.MOUNT_CHURN -> {
            // Destroy 50 widgets, create 50 new ones (deterministic LCG picks
            // the victims), steady-state pool 500.
            repeat(CHURN_PER_FRAME) { churnPool.removeAt(nextChurnIndex(churnPool.size)) }
            repeat(CHURN_PER_FRAME) { churnPool += churnNextId++ }
        }
        else -> {}
    }
}

private fun SceneState.nextChurnIndex(max: Int): Int {
    lcg = lcg * 6364136223846793005L + 1442695040888963407L
    return ((lcg ushr 33) % max).toInt()
}

@Composable
internal fun SceneState.StressContent() {
    when (scene) {
        BenchScene.ELEVATION_GRID -> ElevationGridScene()
        BenchScene.MOUNT_CHURN -> MountChurnScene()
        else -> {}
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
