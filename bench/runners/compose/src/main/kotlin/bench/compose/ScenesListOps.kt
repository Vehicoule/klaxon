// ScenesListOps.kt — Family A of the schema-v2 catalogue (bench-scenes.md):
// the six krausest js-framework-benchmark list operations, natively adapted.
//
// One shared row widget — 48 dp height, label `"Row NNNN — klaxon bench"`
// left, a 16x16 #7C4DFF square right — in a LazyColumn filling the 640x480
// viewport. The op runs inside the frame-WARMUP tick; the harness times that
// frame (mutation + one full render pass) as extra.op_ms and collects frame
// timing over the 60 frames after it. Per the spec, LazyColumn stays
// virtualized (it is the framework's idiom): the op measures the
// model -> render path, not layout of 1000 live nodes.

package bench.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** list_ops model: one row's identity + label (keys follow `id`). */
data class ListRowModel(val id: Int, val label: String)

/** `"Row NNNN — klaxon bench"` — NNNN is the row's zero-padded id. */
private fun listRowLabel(id: Int) = "Row ${"%04d".format(id)} — klaxon bench"

const val LIST_ROWS = 1_000

/// Populate the initial model: 1000 rows for every list op EXCEPT
/// list_create_1k, which starts empty (its op IS the create).
internal fun SceneState.initListOps() {
    listRows.clear()
    listRowNextId = 0
    if (scene == BenchScene.LIST_CREATE_1K) return
    repeat(LIST_ROWS) {
        listRows += ListRowModel(listRowNextId, listRowLabel(listRowNextId))
        listRowNextId++
    }
}

/// The op fires inside the frame-WARMUP tick (frame 10 — right after warmup);
/// the harness times that tick + render pass as extra.op_ms.
internal fun SceneState.tickListOps(frame: Long, harness: Harness) {
    if (frame != WARMUP_FRAMES.toLong()) return
    when (scene) {
        BenchScene.LIST_CREATE_1K -> repeat(LIST_ROWS) {
            listRows += ListRowModel(listRowNextId, listRowLabel(listRowNextId))
            listRowNextId++
        }

        // swap all 1000 row models -> full rebuild render
        BenchScene.LIST_REPLACE_1K -> for (i in 0 until listRows.size) {
            val id = listRowNextId++
            listRows[i] = ListRowModel(id, listRowLabel(id))
        }

        // mutate every 10th row label (100 updates), models swapped in place
        BenchScene.LIST_UPDATE_10TH -> for (i in 0 until listRows.size step 10) {
            listRows[i] = listRows[i].copy(label = listRows[i].label + " !")
        }

        // swap row 5 <-> row 995 contents (the labels move; ids/keys stay put)
        BenchScene.LIST_SWAP_ROWS -> {
            val a = listRows[5]
            val b = listRows[995]
            listRows[5] = a.copy(label = b.label)
            listRows[995] = b.copy(label = a.label)
        }

        // delete the middle row
        BenchScene.LIST_REMOVE_ROW -> listRows.removeAt(listRows.size / 2)

        // remove all rows -> render the empty state
        BenchScene.LIST_CLEAR_1K -> listRows.clear()

        else -> {}
    }
}

@Composable
internal fun SceneState.ListOpsContent() {
    // Plain rows in a scrollable column over the whole 640x480 viewport.
    LazyColumn(Modifier.fillMaxSize()) {
        items(listRows, key = { it.id }) { row -> ListOpsRow(row) }
    }
}

/// The shared row widget: 48 dp, label left, 16x16 #7C4DFF square right.
@Composable
internal fun ListOpsRow(row: ListRowModel) {
    Row(
        Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            row.label,
            fontSize = 14.sp,
            color = Color.White,
            maxLines = 1,
            modifier = Modifier.weight(1f),
        )
        Box(Modifier.size(16.dp).background(PURPLE))
    }
}
