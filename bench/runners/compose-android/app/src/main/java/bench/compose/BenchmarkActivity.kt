// BenchmarkActivity.kt — the launcher activity + scene host.
//
// Launch = bench run (like the Klaxon APK's debug.klaxon.bench=1 mode):
//   adb shell am start -n com.klaxon.bench.compose/bench.compose.BenchmarkActivity
// Extras (all optional):
//   -e scenes "hello,scroll_10k"   comma-separated subset (default: all)
//   --ei warmup N --ei frames N    frame counts (default 10 / 120; ramp is fixed)
// The report lands in files/bench-compose.json (run-as) and
// /sdcard/Android/data/com.klaxon.bench.compose/files/bench-compose.json (adb pull).
//
// LocalDensity is forced to 1.0 for the whole tree: Klaxon lays out in raw
// pixels (no density scaling) — with density=1 the scene's dp/sp values are
// device pixels, so 36px rows / 14px text / 880px list caps are bit-identical
// work units on both sides. The surface itself is the full panel for both
// (decorFitsSystemWindows=false), matching the tier-2 Android Klaxon run.

package bench.compose

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.runtime.CompositionLocalProvider
import androidx.core.view.WindowCompat

private const val TAG = "KlaxonBench"

class BenchmarkActivity : ComponentActivity() {

    private lateinit var runner: BenchRunner

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Full-panel surface (like Klaxon's SDL window); bars overlay us.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        runner = BenchRunner(this)
        runner.debugLog = intent.getBooleanExtra("debug", false)
        setContent { BenchRoot(runner) }

        // Per-frame phase metrics for the activity window (UI thread).
        window.addOnFrameMetricsAvailableListener(runner, Handler(Looper.getMainLooper()))

        val scenes = parseScenes(intent.getStringExtra("scenes"))
        val warmup = intent.getIntExtra("warmup", WARMUP_FRAMES)
        val measured = intent.getIntExtra("frames", MEASURED_FRAMES)
        Log.i(TAG, "launch: scenes=${scenes.joinToString(",") { it.sceneName }} warmup=$warmup frames=$measured")
        runner.launch(scenes, warmup, measured)
    }

    override fun onDestroy() {
        window.removeOnFrameMetricsAvailableListener(runner)
        super.onDestroy()
    }

    private fun parseScenes(arg: String?): List<BenchScene> {
        if (arg.isNullOrBlank()) return BenchScene.entries.toList()
        val scenes = arg.split(',').mapNotNull {
            BenchScene.fromName(it.trim()).also { s ->
                if (s == null) Log.w(TAG, "unknown scene '$it' — skipping")
            }
        }
        return scenes.ifEmpty { BenchScene.entries.toList() }
    }
}

/// Root composable: full-panel BG (Klaxon's clear color), the scene content,
/// and a status line. The drawBehind heartbeat read + onSceneFrame() tick are
/// the frame-production loop: every recorded frame runs exactly one scene
/// tick and re-invalidates this draw scope for the next traversal, so the
/// runner produces frames as fast as the render pipeline will take them
/// (Klaxon repaints unconditionally — see Bench.kt's timing-model notes).
@Composable
private fun BenchRoot(runner: BenchRunner) {
    CompositionLocalProvider(LocalDensity provides Density(1f, 1f)) {
        Box(
            Modifier
                .fillMaxSize()
                .background(BG)
                .drawBehind {
                    runner.heartbeat.longValue // tracked read: keep re-recording
                    runner.onSceneFrame() // one scene tick per recorded frame
                },
        ) {
            runner.currentState?.Content()
            Text(
                "klaxon bench — compose android: ${runner.statusText}",
                fontSize = 10.sp,
                color = Color(0xFF555566),
                modifier = Modifier.align(Alignment.BottomStart).padding(4.dp),
            )
        }
    }
}
