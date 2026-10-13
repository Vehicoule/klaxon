// ComposeHost — the real Compose Multiplatform mount.
//
// Headless by construction (the bench runner's recipe): a
// CanvasLayersComposeScene renders into a CPU raster Skiko surface — no
// window, no GPU, no vsync. The mounted composition mirrors the KNode
// model one-to-one:
//
//   - every KNode becomes a real `Layout` composable — the LayoutNode tree,
//     placements and measured sizes are produced by Compose's own layout
//     pass (the policies place children at the model-computed bounds, which
//     is exactly where the shared ported algorithm put them);
//   - every node's paint ops run through a real `drawBehind` DrawScope onto
//     the Skiko surface (fillRect / drawRoundRect / direct-Skia text lines
//     — drawSimpleText semantics, no bidi, like the reference kx_draw_text);
//   - scroll containers get `clipToBounds()` — the real Compose clip;
//   - semantic nodes carry a custom SemanticsProperty; the `a11y` expect
//     walks the real SemanticsOwner tree (falling back to the model flatten
//     only if the reflective bridge fails — documented in MAPPING.md);
//   - pixels are read back from the Skiko surface after scene.render().
@file:OptIn(InternalComposeUiApi::class, ExperimentalComposeApi::class)

package conf.compose

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ExperimentalComposeApi
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asComposeCanvas
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasurePolicy
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.platform.PlatformContext
import androidx.compose.ui.platform.WindowInfo
import androidx.compose.ui.scene.CanvasLayersComposeScene
import androidx.compose.ui.scene.ComposeScene
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsOwner
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.Font
import org.jetbrains.skia.FontMgr
import org.jetbrains.skia.FontStyle
import org.jetbrains.skia.ImageInfo
import org.jetbrains.skia.Surface
import org.jetbrains.skia.TextLine
import org.jetbrains.skia.Typeface

/** DSL colors are RRGGBBAA; Compose/Skia ARGB is AARRGGBB. */
fun rrggbbaa(c: Long): Color = Color((((c and 0xFF) shl 24) or (c ushr 8)).toInt())
fun argbToRrggbbaa(argb: Int): Long =
    (((argb and 0xFFFFFF).toLong() shl 8) or ((argb ushr 24).toLong())) and 0xFFFFFFFFL

/** Carries the adapter's Semantics record through the real Compose
 *  semantics tree so expectA11y reads framework-produced structure. */
val KlaxonSemanticsKey = SemanticsPropertyKey<Semantics2>("KlaxonSemantics")

/** A rasterized frame (the pixel_* expects' surface). */
class Frame(val w: Int, val h: Int, val argb: IntArray) {
    fun pixelAt(x: Int, y: Int): Long {
        if (x < 0 || y < 0 || x >= w || y >= h) return 0L
        return argbToRrggbbaa(argb[y * w + x])
    }
    fun countColor(color: Long): Int {
        val want = rrggbbaaToArgbInt(color)
        var n = 0
        for (p in argb) if (p == want) n++
        return n
    }
    fun countColorIn(r: Rect2, color: Long): Int {
        val want = rrggbbaaToArgbInt(color)
        val x0 = r.x.toInt().coerceIn(0, w); val y0 = r.y.toInt().coerceIn(0, h)
        val x1 = (r.x + r.w).toInt().coerceIn(0, w); val y1 = (r.y + r.h).toInt().coerceIn(0, h)
        var n = 0
        for (y in y0 until y1) for (x in x0 until x1) if (argb[y * w + x] == want) n++
        return n
    }
    companion object {
        fun rrggbbaaToArgbInt(c: Long): Int = (((c and 0xFF) shl 24) or (c ushr 8)).toInt()
    }
}

/** Per-byte channel diff at a byte offset (matches golden.channelDiff —
 *  both operands share the RRGGBBAA packing). */
fun channelDiff(a: Long, b: Long, shift: Int): Long {
    val ca = (a ushr shift) and 0xFF
    val cb = (b ushr shift) and 0xFF
    return if (ca > cb) ca - cb else cb - ca
}

private class HostWindowInfo(override val containerSize: IntSize) : WindowInfo {
    override val isWindowFocused: Boolean = true
}

/** Skia font cache (size,bold) — the same stack kx_make_font uses. */
private object Fonts {
    private val cache = HashMap<Pair<Float, Boolean>, Font>()
    private val normal = try { FontMgr.default.legacyMakeTypeface("", FontStyle.NORMAL) } catch (e: Exception) { null }
    private val bold = try { FontMgr.default.legacyMakeTypeface("", FontStyle.BOLD) } catch (e: Exception) { normal }
    fun get(size: Float, isBold: Boolean): Font = cache.getOrPut(size to isBold) {
        val tf = if (isBold) bold else normal
        if (tf != null) Font(tf, size) else Font().also { it.size = size }
    }
}

/** DrawScope-backed PaintSink: real Compose draw calls onto the Skiko
 *  canvas. Node paint fns emit parent-space coords — the sink re-bases
 *  them to the node's local origin (bounds.x/y) like the reference ctx. */
private class ComposeSink(val scope: DrawScope, val node: KNode) : PaintSink {
    override fun fillRect(x: Float, y: Float, w: Float, h: Float, color: Long) {
        scope.drawRect(rrggbbaa(color),
            topLeft = androidx.compose.ui.geometry.Offset(x - node.bounds.x, y - node.bounds.y),
            size = androidx.compose.ui.geometry.Size(w, h))
    }
    override fun fillRRect(x: Float, y: Float, w: Float, h: Float, radius: Float, color: Long) {
        scope.drawRoundRect(rrggbbaa(color),
            topLeft = androidx.compose.ui.geometry.Offset(x - node.bounds.x, y - node.bounds.y),
            size = androidx.compose.ui.geometry.Size(w, h),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius, radius))
    }
    override fun text(text: String, x: Float, yBaseline: Float, size: Float, bold: Boolean, color: Long) {
        if (text.isEmpty()) return
        val font = Fonts.get(size, bold)
        val line = TextLine.make(text, font)
        val paint = org.jetbrains.skia.Paint().apply {
            this.color = Frame.rrggbbaaToArgbInt(color)
            isAntiAlias = true
        }
        // drawSimpleText semantics: UTF-8 glyphs at (x, baseline), no bidi.
        val canvas = scope.drawContext.canvas.nativeCanvas
        canvas.drawTextLine(line, x - node.bounds.x, yBaseline - node.bounds.y, paint)
    }
}

object ComposeHost {
    private var scene: ComposeScene? = null
    private var surface: Surface? = null
    private var engine: Engine? = null
    private var surfaceW = 0
    private var surfaceH = 0
    private var mounted = false

    /** Bumped before every render so recomposition re-reads the (mutable)
     *  model — one recompose + layout + draw pass per rendered frame. */
    private val frameVersion = mutableLongStateOf(0L)

    /** Install the real (Skia) text metrics provider — identical to
     *  kx_measure_text: SkFont.measureText + SkFontMetrics. */
    fun installTextMeasure() {
        TextMeasure.provider = { text, size, bold ->
            if (text.isEmpty()) TextMetrics(0f, 0f, 0f)
            else {
                val font = Fonts.get(size, bold)
                val m = font.metrics
                val ascent = -m.ascent
                val descent = m.descent
                TextMetrics(font.measureTextWidth(text), ascent + descent, ascent)
            }
        }
    }

    /** Mount (or re-mount) the engine's tree in the scene. Deferred until
     *  the first render/semantics read — pure-logic domains never pay for
     *  the composition. */
    fun mount(e: Engine) {
        engine = e
        mounted = false
    }

    fun forEngine(e: Engine): ComposeHost {
        if (engine !== e || !mounted) mount(e)
        ensureScene(e)
        if (!mounted) {
            scene!!.setContent { RootContent(e) }
            mounted = true
        }
        ensureSurface(e)
        return this
    }

    private fun ensureScene(e: Engine) {
        if (scene != null) return
        val wi = HostWindowInfo(IntSize(e.viewport.w.toInt(), e.viewport.h.toInt()))
        val platformContext = object : PlatformContext by PlatformContext.Empty {
            override val windowInfo: WindowInfo get() = wi
        }
        scene = CanvasLayersComposeScene(
            density = Density(1f),
            layoutDirection = LayoutDirection.Ltr,
            size = IntSize(e.viewport.w.toInt(), e.viewport.h.toInt()),
            coroutineContext = Dispatchers.Unconfined,
            platformContext = platformContext,
            invalidate = {},
        )
    }

    private fun ensureSurface(e: Engine) {
        val w = e.viewport.w.toInt().coerceAtLeast(1)
        val h = e.viewport.h.toInt().coerceAtLeast(1)
        if (surface == null || surfaceW != w || surfaceH != h) {
            surface?.close()
            surface = Surface.makeRasterN32Premul(w, h)
            surfaceW = w; surfaceH = h
            scene?.size = IntSize(w, h)
        }
    }

    fun resize(w: Int, h: Int) {
        engine?.let { e ->
            e.viewport.w = w.toFloat(); e.viewport.h = h.toFloat()
            ensureSurface(e)
        }
    }

    /** One real frame: bump the version → recompose → measure/layout →
     *  draw, all synchronously inside scene.render — then read the Skiko
     *  surface back. Damage is NOT cleared here (renderFrame does that). */
    fun render(): Frame {
        val e = engine ?: return Frame(0, 0, IntArray(0))
        ensureSurface(e)
        val s = surface!!
        frameVersion.longValue++
        s.canvas.clear(0xFF000000.toInt()) // the reference paints on black
        scene!!.render(s.canvas.asComposeCanvas(), System.nanoTime())
        val img = s.makeImageSnapshot()
        val bmp = Bitmap()
        bmp.allocPixels(ImageInfo.makeN32Premul(surfaceW, surfaceH))
        check(img.readPixels(bmp)) { "pixel readback failed" }
        // N32 premul on little-endian hosts is B,G,R,A bytes — repack to
        // ARGB ints (the Frame contract).
        val bytes = bmp.readPixels() ?: error("pixel readback returned null")
        val pixels = IntArray(surfaceW * surfaceH)
        var i = 0
        var j = 0
        while (i < pixels.size) {
            val b = bytes[j].toInt() and 0xFF
            val g = bytes[j + 1].toInt() and 0xFF
            val r = bytes[j + 2].toInt() and 0xFF
            val a = bytes[j + 3].toInt() and 0xFF
            pixels[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
            i += 1; j += 4
        }
        img.close()
        return Frame(surfaceW, surfaceH, pixels)
    }

    // --- composition ------------------------------------------------------

    @Composable
    private fun RootContent(e: Engine) {
        frameVersion.longValue // observe — forces a full recompose per frame
        val root = e.root ?: return
        NodeView(root, semanticsAllowed = true)
    }

    /** One KNode → one real Compose Layout. The model has already run
     *  measure+layout (the vectors assert those coordinates); the policies
     *  mirror them: fixed model size, children placed at model positions
     *  (scroll children at -offset inside a real clipToBounds). */
    @Composable
    private fun NodeView(node: KNode, semanticsAllowed: Boolean) {
        frameVersion.longValue
        val includeSem = semanticsAllowed && node.visible && !node.excludeSemantics
        val sem = if (includeSem) node.semantics else null
        var mod: Modifier = Modifier
        if (sem != null) {
            mod = mod.semantics(mergeDescendants = false) {
                this[KlaxonSemanticsKey] = sem
            }
        }
        mod = mod.drawBehind {
            val pf = node.paintFn
            if (pf != null && node.visible) pf(node, ComposeSink(this, node))
        }
        if (node.childClip != null) mod = mod.clipToBounds()
        val childAllowed = includeSem
        Layout(
            content = { for (child in node.children) NodeView(child, childAllowed) },
            modifier = mod,
            measurePolicy = object : MeasurePolicy {
                override fun MeasureScope.measure(
                    measurables: List<Measurable>,
                    constraints: Constraints,
                ): MeasureResult {
                    val w = node.bounds.w.roundToInt().coerceAtLeast(0)
                    val h = node.bounds.h.roundToInt().coerceAtLeast(0)
                    val offset = scrollOffsetOf(node)
                    val placeables = measurables.mapIndexed { i, m ->
                        val child = node.children[i]
                        // The child reports its model size; constraints stay
                        // loose — scroll content is taller than the viewport
                        // by design (the clip is real).
                        m.measure(Constraints(
                            minWidth = 0, maxWidth = Constraints.Infinity,
                            minHeight = 0, maxHeight = Constraints.Infinity))
                    }
                    return layout(w, h) {
                        placeables.forEachIndexed { i, p ->
                            val child = node.children[i]
                            p.place(
                                (child.bounds.x - node.bounds.x).roundToInt(),
                                (child.bounds.y - node.bounds.y - offset).roundToInt())
                        }
                    }
                }
            },
        )
    }

    // --- real semantics tree ----------------------------------------------

    /** The scene's Owner via the RootNodeOwner bridge (same reflection the
     *  bench runner uses — ComposeScene exposes no owner accessor). */
    private fun sceneOwner(s: ComposeScene): Any? {
        return try {
            val mainOwnerField = s.javaClass.getDeclaredField("mainOwner").apply { isAccessible = true }
            val rootNodeOwner = mainOwnerField.get(s)
            rootNodeOwner.javaClass.getMethod("getOwner").invoke(rootNodeOwner)
        } catch (t: Throwable) { null }
    }

    /** The real Compose semantics tree as SemanticNode2s — returns null if
     *  the reflective bridge fails (the caller falls back to the model). */
    fun semanticTree(): SemanticNode2? {
        val s = scene ?: return null
        return try {
            val owner = sceneOwner(s) ?: return null
            val semOwner = owner.javaClass.getMethod("getSemanticsOwner")
                .apply { isAccessible = true }.invoke(owner) as SemanticsOwner
            val root = try {
                semOwner.unmergedRootSemanticsNode
            } catch (t: Throwable) {
                semOwner.rootSemanticsNode
            }
            // Compose's root is a synthetic wrapper (like our group node):
            // single semantic child → that child; else a group wrapper.
            val kids = root.children.map { toSemanticNode(it) }.filterNotNull()
            if (kids.size == 1) kids[0]
            else SemanticNode2(engine?.root ?: KNode("root")).also {
                it.role = SemRole.GROUP
                it.children.addAll(kids)
            }
        } catch (t: Throwable) { null }
    }

    private fun toSemanticNode(sn: SemanticsNode): SemanticNode2? {
        val sem = sn.config.getOrElseNullable(KlaxonSemanticsKey) { null } ?: return null
        val model = findModelNode(sem) ?: return null
        val out = SemanticNode2(model)
        out.role = sem.role
        out.label = if (sem.label.isNotEmpty()) sem.label else firstDescendantLabel(model) ?: ""
        out.hint = sem.hint
        out.value = sem.value
        out.checked = sem.checked
        out.disabled = sem.disabled
        out.focusable = sem.focusable
        out.actions = sem.actions.copy()
        for (c in sn.children) toSemanticNode(c)?.let { out.children.add(it) }
        return out
    }

    /** The modifier carries the node's LIVE Semantics2 — identity link back
     *  to the KNode via a per-read identity map. */
    private var semIdentity: java.util.IdentityHashMap<Semantics2, KNode>? = null

    private fun findModelNode(sem: Semantics2): KNode? {
        val e = engine ?: return null
        var map = semIdentity
        if (map == null) {
            map = java.util.IdentityHashMap()
            fun walk(n: KNode) {
                if (!n.visible || n.excludeSemantics) return
                n.semantics?.let { map[it] = n }
                for (c in n.children) walk(c)
            }
            e.root?.let { walk(it) }
            semIdentity = map
        }
        return map[sem]
    }

    fun resetSemModelWalk() { semIdentity = null }
}
