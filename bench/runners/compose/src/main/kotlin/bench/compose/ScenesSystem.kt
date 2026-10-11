// ScenesSystem.kt — Family D of the schema-v2 catalogue (bench-scenes.md):
// the four non-paint system scenes.
//
//   input_latency    a synthetic Press is injected at LATENCY_INJECT_FRAME via
//                    ComposeScene.sendPointerEvent; extra.latency_frames counts
//                    renders from the injection to the frame that paints the
//                    response, extra.latency_ms the wall time between them.
//   pointer_storm    1000 hit-test queries (move events) per frame over a
//                    ~500-node tree of pointerInput targets; no paint change.
//   semantics_build  build/diff the merged a11y semantics tree of a 1000-node
//                    tree each frame — the walk runs in postRender inside the
//                    timed frame; extra.nodes_per_frame is the walked count.
//   app_switch       one pause->resume cycle every APP_SWITCH_PERIOD frames:
//                    dispose + recreate the scene (the headless analog — see
//                    README); extra.teardown_ms / extra.resume_ms.

package bench.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** semantics_build: the tree's node count (one semantics-bearing Text each). */
const val SEMANTICS_NODES = 1_000

/** pointer_storm: hit-test queries per frame (spec: 1000). */
const val HIT_TESTS_PER_FRAME = 1_000

internal fun SceneState.tickSystem(frame: Long, harness: Harness) {
    animFrame.longValue = frame
    when (scene) {
        BenchScene.INPUT_LATENCY -> if (frame == LATENCY_INJECT_FRAME) requestPointerInjection()

        BenchScene.POINTER_STORM -> {
            // 1000 hit-test queries over the ~500-node tree. Deterministic
            // pseudo-scatter so every query hits a different area; move events
            // run the full hit-test dispatch without changing any paint state.
            for (k in 0 until HIT_TESTS_PER_FRAME) {
                harness.sendPointerMove(
                    x = ((k * 37 + frame * 11) % 633).toFloat() + 4f,
                    y = ((k * 61 + frame * 7) % 473).toFloat() + 4f,
                )
            }
        }

        BenchScene.SEMANTICS_BUILD -> {
            // Invalidate a rotating 100-node window of descriptions each frame
            // (all 1000 cycle every 10 frames): the "diff" half of build/diff —
            // the walk in postRender rebuilds those nodes' semantics.
            val window = ((frame % 10).toInt()) * (SEMANTICS_NODES / 10)
            for (i in window until window + SEMANTICS_NODES / 10) {
                semStates[i].longValue = frame
            }
        }

        BenchScene.APP_SWITCH -> if (frame > 0 && frame % APP_SWITCH_PERIOD == 0L) {
            harness.pauseResumeCycle()
        }

        else -> {}
    }
}

/// semantics_build: after the render, walk + count the merged a11y semantics
/// tree — inside the same timed frame (the "build" half of build/diff).
internal fun SceneState.postRenderSemantics(frame: Long, harness: Harness) {
    if (frame >= WARMUP_FRAMES) {
        semNodesSum += harness.countSemanticsNodes()
        semNodesSamples++
    }
}

@Composable
internal fun SceneState.SystemContent() {
    when (scene) {
        BenchScene.INPUT_LATENCY -> InputLatencyScene()
        BenchScene.POINTER_STORM -> PointerStormScene()
        BenchScene.SEMANTICS_BUILD -> SemanticsBuildScene()
        BenchScene.APP_SWITCH -> AppSwitchScene()
        else -> {}
    }
}

// --- input_latency: ambient tree + a centered 200x200 press target ---

@Composable
private fun SceneState.InputLatencyScene() {
    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            repeat(12) { i -> Text("menu item $i", fontSize = 14.sp, color = Color(0xFFCCCCCC)) }
        }
        // The press target: the injected Press lands at (320, 240) — inside
        // this centered 200x200 box — and flips it purple -> teal.
        Box(
            Modifier
                .size(200.dp)
                .align(Alignment.Center)
                .clip(RoundedCornerShape(12.dp))
                .background(responseColor)
                .pointerInput(Unit) {
                    awaitEachGesture {
                        awaitFirstDown()
                        responseArrived = true
                        responseColor = TEAL
                    }
                },
        )
    }
}

// --- pointer_storm: ~500 hit-testable nodes ---

@Composable
private fun PointerStormScene() {
    // A 25x20 grid of 500 boxes, each with a pointerInput handler so the
    // hit-test dispatch has real targets to visit (the handlers are empty —
    // no paint change, pure hit-test cost, per the spec).
    SimpleGrid(Modifier.fillMaxSize(), columns = 25, hGap = 4.dp, vGap = 4.dp, padding = 8.dp) {
        repeat(500) { i ->
            Box(
                Modifier
                    .size(20.dp, 18.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(if (i % 2 == 0) PURPLE else TEAL)
                    .pointerInput(Unit) {},
            )
        }
    }
}

// --- semantics_build: a 1000-node tree whose a11y tree is walked each frame ---

@Composable
private fun SceneState.SemanticsBuildScene() {
    // 1000 semantics-bearing texts; each node's TEXT reads its own per-node
    // state so the tick's rotating 100-node window recomposes (the text is
    // itself a semantics property → a real per-frame semantics diff, not just
    // a stale-tree re-walk). The contentDescription rides along.
    Column(Modifier.fillMaxSize()) {
        repeat(SEMANTICS_NODES) { i ->
            Text(
                "Node $i — semantics v${semStates[i].longValue}",
                fontSize = 10.sp,
                color = Color(0xFFCCCCCC),
                maxLines = 1,
                modifier = Modifier.semantics {
                    contentDescription = "Node $i v${semStates[i].longValue}"
                },
            )
        }
    }
}

// --- app_switch: a mid-size tree the pause->resume cycle tears down + rebuilds ---

@Composable
private fun SceneState.AppSwitchScene() {
    val theme = themePalette
    Column(
        Modifier.fillMaxSize().background(theme.bg).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("app_switch — pause->resume every 60 frames", fontSize = 14.sp, color = theme.text)
        repeat(30) { i -> AppSwitchCard(i) }
    }
}

@Composable
private fun SceneState.AppSwitchCard(i: Int) {
    val theme = themePalette
    Row(
        Modifier
            .fillMaxWidth()
            .height(44.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(theme.surface)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.size(20.dp).clip(RoundedCornerShape(4.dp)).background(theme.accent))
        Column {
            Text("Card $i", fontSize = 13.sp, color = theme.text, maxLines = 1)
            Text("detail", fontSize = 10.sp, color = theme.dim, maxLines = 1)
        }
        Spacer(Modifier.weight(1f))
        Text("$i", fontSize = 12.sp, color = theme.dim)
    }
}
