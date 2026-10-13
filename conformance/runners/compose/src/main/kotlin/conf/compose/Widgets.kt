// DSL → node builders — Kotlin port of conformance.zig's buildNode plus the
// widget vtables it instantiates (src/widgets/*). Each builder produces a
// KNode with measure/layout/paint/pointer/key/scroll handlers that mirror
// the reference widget exactly — same sizes, same colors, same behaviors.
package conf.compose

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// ---------------------------------------------------------------- helpers

fun JVal?.prop(name: String): JVal? = this?.obj?.get(name)
fun JVal.numOr(default: Float): Float = (this as? JVal.JNum)?.v?.toFloat() ?: default
fun JVal?.numOf(default: Float): Float = this?.numOr(default) ?: default
fun JVal?.intOf(default: Long): Long = when (this) {
    is JVal.JNum -> v.toLong()
    else -> default
}
fun JVal?.strOr(default: String): String = (this as? JVal.JStr)?.v ?: default
fun JVal?.boolOr(default: Boolean): Boolean = (this as? JVal.JBool)?.v ?: default

fun parseColorV(v: JVal?): Long? = when (v) {
    is JVal.JNum -> v.v.toLong() and 0xFFFFFFFFL
    is JVal.JStr -> {
        val hex = if (v.v.startsWith("#")) v.v.substring(1) else v.v
        if (hex.length != 8) null else hex.toLongOrNull(16)
    }
    else -> null
}

fun parseRectV(v: JVal?): Rect2? {
    val a = v?.arr ?: return null
    if (a.size < 4) return null
    return Rect2(a[0].numOr(0f), a[1].numOr(0f), a[2].numOr(0f), a[3].numOr(0f))
}

fun parseInsetsV(v: JVal?): EdgeInsets2? {
    if (v == null || v is JVal.JNull) return null
    v.obj?.let { o ->
        return EdgeInsets2(
            o["left"].numOf(0f), o["top"].numOf(0f),
            o["right"].numOf(0f), o["bottom"].numOf(0f))
    }
    val a = v.numOr(-1f)
    return if (a < 0) null else EdgeInsets2.all(a)
}

fun parseDirInsetsV(v: JVal?): EdgeInsetsDir? {
    val o = v?.obj ?: return null
    return EdgeInsetsDir(
        o["start"].numOf(0f), o["end"].numOf(0f),
        o["top"].numOf(0f), o["bottom"].numOf(0f))
}

fun parseMainAlignV(s: String) = when (s) {
    "center" -> MainAlign.CENTER; "end" -> MainAlign.END
    "space_between" -> MainAlign.SPACE_BETWEEN; "space_around" -> MainAlign.SPACE_AROUND
    "space_evenly" -> MainAlign.SPACE_EVENLY; else -> MainAlign.START
}
fun parseCrossAlignV(s: String) = when (s) {
    "start" -> CrossAlign.START; "center" -> CrossAlign.CENTER
    "end" -> CrossAlign.END; else -> CrossAlign.STRETCH
}
fun parseTextAlignV(s: String) = when (s) {
    "center" -> TextAlign.CENTER; "right" -> TextAlign.RIGHT
    "start" -> TextAlign.START; "end" -> TextAlign.END; else -> TextAlign.LEFT
}
fun parseAlignmentV(v: JVal?): Alignment2? {
    val a = v?.arr ?: return null
    if (a.size < 2) return null
    return Alignment2(a[0].numOr(0f), a[1].numOr(0f))
}

fun direction(): Direction = Engine.current?.i18n?.direction() ?: Direction.LTR

// ---------------------------------------------------------------- leaf "box"

class BoxState(
    val engine: Engine,
    val id: String,
    val w: Float = 0f,
    val h: Float = 0f,
    val color: Long = 0xCCCCCCFF,
    val onPress: Boolean = false,
    var itemIndex: Int = Int.MAX_VALUE,
)

fun makeBox(e: Engine, id: String, w: Float, h: Float, color: Long, onPress: Boolean): KNode {
    val n = KNode("box")
    val s = BoxState(e, id, w, h, color, onPress)
    n.state = s
    n.measurer = { node, c -> c.constrain(Size2(s.w, s.h)) }
    n.layouter = { _, _ -> }
    n.paintFn = { node, sink -> sink.fillRect(node.bounds.x, node.bounds.y, node.bounds.w, node.bounds.h, s.color) }
    n.pointerHandler = { node, ev ->
        if (!s.onPress) false else when (ev.phase) {
            PointerPhase.DOWN -> true
            PointerPhase.UP -> {
                if (node.bounds.contains(ev.x, ev.y)) e.events.add("press:${s.id}")
                true
            }
            else -> true
        }
    }
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

// ---------------------------------------------------------------- flex

class FlexState(val axis: Axis, val gap: Float, val padding: Float,
                val mainAlign: MainAlign, val crossAlign: CrossAlign)

fun flexMeasure(n: KNode, c: Constraints2): Size2 {
    val s = n.state as FlexState
    val inner = c.deflate(s.padding * 2)
    val gaps = if (n.children.size > 1) s.gap * (n.children.size - 1) else 0f
    var mainTotal = 0f
    var crossMax = 0f
    var flexTotal = 0
    var nonFlexMain = 0f
    for (child in n.children) {
        if (child.flex > 0) { flexTotal += child.flex; continue }
        val size = child.measure(inner.loosenMain(s.axis))
        nonFlexMain += size.main(s.axis)
        crossMax = max(crossMax, size.cross(s.axis))
    }
    val innerMainMax = if (s.axis == Axis.HORIZONTAL) inner.maxW else inner.maxH
    if (flexTotal > 0 && innerMainMax.isFinite()) {
        val remaining = max(0f, innerMainMax - nonFlexMain - gaps)
        for (child in n.children) {
            if (child.flex == 0) continue
            val alloc = remaining * child.flex / flexTotal
            val childC = if (s.axis == Axis.HORIZONTAL)
                Constraints2(alloc, alloc, 0f, inner.maxH)
            else Constraints2(0f, inner.maxW, alloc, alloc)
            val size = child.measure(childC)
            mainTotal += alloc
            crossMax = max(crossMax, size.cross(s.axis))
        }
    } else {
        for (child in n.children) {
            if (child.flex == 0) continue
            val size = child.measure(inner.loosenMain(s.axis))
            mainTotal += size.main(s.axis)
            crossMax = max(crossMax, size.cross(s.axis))
        }
    }
    mainTotal += nonFlexMain + gaps
    return c.constrain(Size2.fromMainCross(s.axis, mainTotal + s.padding * 2, crossMax + s.padding * 2))
}

fun flexLayout(n: KNode, bounds: Rect2) {
    val s = n.state as FlexState
    val count = n.children.size
    if (count == 0) return
    val sizes = arrayOfNulls<Size2>(count)
    val innerMain = max(0f, (if (s.axis == Axis.HORIZONTAL) bounds.w else bounds.h) - s.padding * 2)
    val crossAvail = max(0f, (if (s.axis == Axis.HORIZONTAL) bounds.h else bounds.w) - s.padding * 2)

    var naturalMain = s.padding * 2
    var flexTotal = 0
    var nonFlexMain = 0f
    val gapsTotal = if (count > 1) s.gap * (count - 1) else 0f
    for (i in 0 until count) {
        val child = n.children[i]
        if (child.flex > 0) { flexTotal += child.flex; continue }
        val childC = if (s.axis == Axis.HORIZONTAL)
            Constraints2(0f, innerMain, 0f, crossAvail) else Constraints2(0f, crossAvail, 0f, innerMain)
        sizes[i] = child.measure(childC)
        nonFlexMain += sizes[i]!!.main(s.axis)
    }
    val remaining = max(0f, innerMain - nonFlexMain - gapsTotal)
    for (i in 0 until count) {
        val child = n.children[i]
        if (child.flex == 0) continue
        val childC: Constraints2
        if (flexTotal > 0 && innerMain.isFinite()) {
            val alloc = remaining * child.flex / flexTotal
            childC = if (s.axis == Axis.HORIZONTAL)
                Constraints2(alloc, alloc, 0f, crossAvail) else Constraints2(0f, crossAvail, alloc, alloc)
        } else {
            childC = if (s.axis == Axis.HORIZONTAL)
                Constraints2(0f, innerMain, 0f, crossAvail) else Constraints2(0f, crossAvail, 0f, innerMain)
        }
        sizes[i] = child.measure(childC)
    }
    for (sz in sizes) naturalMain += sz!!.main(s.axis)
    naturalMain += gapsTotal

    val boundMain = if (s.axis == Axis.HORIZONTAL) bounds.w else bounds.h
    val free = max(0f, boundMain - naturalMain)
    var start = s.padding
    var extraGap = 0f
    when (s.mainAlign) {
        MainAlign.START -> {}
        MainAlign.CENTER -> start += free / 2
        MainAlign.END -> start += free
        MainAlign.SPACE_BETWEEN -> if (count > 1) extraGap = free / (count - 1)
        MainAlign.SPACE_AROUND -> { val nf = count.toFloat(); start += free / (2 * nf); extraGap = free / nf }
        MainAlign.SPACE_EVENLY -> { val nf = (count + 1).toFloat(); start += free / nf; extraGap = free / nf }
    }

    val rtl = s.axis == Axis.HORIZONTAL && direction() == Direction.RTL
    var cursor = start
    for (i in 0 until count) {
        val sz = sizes[i]!!
        val crossPos = when (s.crossAlign) {
            CrossAlign.START, CrossAlign.STRETCH -> s.padding
            CrossAlign.CENTER -> s.padding + (crossAvail - sz.cross(s.axis)) / 2
            CrossAlign.END -> s.padding + (crossAvail - sz.cross(s.axis))
        }
        val crossSize = if (s.crossAlign == CrossAlign.STRETCH) crossAvail else min(sz.cross(s.axis), crossAvail)
        val mainPos = if (rtl) bounds.w - cursor - sz.w else cursor
        val childBounds = if (s.axis == Axis.HORIZONTAL)
            Rect2(bounds.x + mainPos, bounds.y + crossPos, sz.w, crossSize)
        else Rect2(bounds.x + crossPos, bounds.y + cursor, crossSize, sz.h)
        n.children[i].layout(childBounds)
        cursor += sz.main(s.axis) + s.gap + extraGap
    }
}

fun makeFlex(axis: Axis, gap: Float, padding: Float, mainAlign: MainAlign, crossAlign: CrossAlign): KNode {
    val n = KNode(if (axis == Axis.HORIZONTAL) "row" else "column")
    n.state = FlexState(axis, gap, padding, mainAlign, crossAlign)
    n.measurer = ::flexMeasure
    n.layouter = ::flexLayout
    return n
}

// ---------------------------------------------------------------- stack

enum class StackFit { LOOSE, EXPAND }
class StackState(val fit: StackFit, val alignment: Alignment2)

fun makeStack(fit: StackFit, alignment: Alignment2): KNode {
    val n = KNode("stack")
    n.state = StackState(fit, alignment)
    n.measurer = { node, c ->
        val s = node.state as StackState
        val expand = s.fit == StackFit.EXPAND
        val childC = if (expand) c else c.loosen()
        var w = 0f; var h = 0f
        for (child in node.children) {
            val cs = child.measure(childC)
            w = max(w, cs.w); h = max(h, cs.h)
        }
        var size = Size2(w, h)
        if (expand) {
            if (c.maxW.isFinite()) size = Size2(c.maxW, size.h)
            if (c.maxH.isFinite()) size = Size2(size.w, c.maxH)
        }
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        val s = node.state as StackState
        val childC = if (s.fit == StackFit.EXPAND)
            Constraints2(bounds.w, bounds.w, bounds.h, bounds.h)
        else Constraints2(0f, bounds.w, 0f, bounds.h)
        for (child in node.children) {
            val cs = child.measure(childC)
            child.layout(s.alignment.mirrored(direction()).position(bounds, cs))
        }
    }
    return n
}

// ---------------------------------------------------------------- grid

class GridState(val columns: Int, val gap: Float, val padding: Float)

fun makeGrid(columns: Int, gap: Float, padding: Float): KNode {
    val n = KNode("grid")
    n.state = GridState(columns, gap, padding)
    n.measurer = { node, c ->
        val s = node.state as GridState
        val cols = max(1, s.columns)
        val count = node.children.size
        if (count == 0) c.constrain(Size2()) else {
            val rows = (count + cols - 1) / cols
            val pad2 = s.padding * 2
            val gapsW = s.gap * (cols - 1)
            val trackW = if (c.maxW.isFinite()) max(0f, (c.maxW - pad2 - gapsW) / cols) else 0f
            val sizes = Array(count) { i ->
                val childC = if (c.maxW.isFinite()) Constraints2(trackW, trackW) else Constraints2()
                node.children[i].measure(childC)
            }
            var maxChildW = 0f
            for (sz in sizes) maxChildW = max(maxChildW, sz.w)
            val tw = if (c.maxW.isFinite()) trackW else maxChildW
            val rowH = FloatArray(rows)
            for (i in 0 until count) rowH[i / cols] = max(rowH[i / cols], sizes[i].h)
            var totalH = pad2
            for (ri in 0 until rows) { totalH += rowH[ri]; if (ri + 1 < rows) totalH += s.gap }
            c.constrain(Size2(tw * cols + gapsW + pad2, totalH))
        }
    }
    n.layouter = { node, bounds ->
        val s = node.state as GridState
        val cols = max(1, s.columns)
        val count = node.children.size
        if (count > 0) {
            val rows = (count + cols - 1) / cols
            val pad2 = s.padding * 2
            val gapsW = s.gap * (cols - 1)
            val trackW = max(0f, (bounds.w - pad2 - gapsW) / cols)
            val sizes = Array(count) { i -> node.children[i].measure(Constraints2(trackW, trackW)) }
            val rowH = FloatArray(rows)
            for (i in 0 until count) rowH[i / cols] = max(rowH[i / cols], sizes[i].h)
            var y = s.padding
            var curRow = 0
            for (i in 0 until count) {
                val rowIdx = i / cols
                if (rowIdx != curRow) { y += rowH[curRow] + s.gap; curRow = rowIdx }
                val x = s.padding + (i % cols) * (trackW + s.gap)
                node.children[i].layout(Rect2(bounds.x + x, bounds.y + y, trackW, rowH[rowIdx]))
            }
        }
    }
    return n
}

// ---------------------------------------------------------------- padding / align / constrained / expanded

fun makePadding(insets: EdgeInsets2): KNode {
    val n = KNode("padding")
    n.state = insets
    n.measurer = { node, c ->
        val inner = c.deflateEdge(insets)
        var size = Size2()
        if (node.children.isNotEmpty()) {
            val cs = node.children[0].measure(inner)
            size = Size2(cs.w + insets.hSum(), cs.h + insets.vSum())
        }
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        if (node.children.isNotEmpty()) {
            node.children[0].layout(Rect2(
                bounds.x + insets.left, bounds.y + insets.top,
                max(0f, bounds.w - insets.hSum()), max(0f, bounds.h - insets.vSum())))
        }
    }
    return n
}

fun makePaddingDir(insets: EdgeInsetsDir): KNode {
    val n = KNode("padding_directional")
    n.state = insets
    fun resolved() = insets.resolve(direction())
    n.measurer = { node, c ->
        val e = resolved()
        val inner = c.deflateEdge(e)
        var size = Size2()
        if (node.children.isNotEmpty()) {
            val cs = node.children[0].measure(inner)
            size = Size2(cs.w + e.hSum(), cs.h + e.vSum())
        }
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        if (node.children.isNotEmpty()) {
            val e = resolved()
            node.children[0].layout(Rect2(
                bounds.x + e.left, bounds.y + e.top,
                max(0f, bounds.w - e.hSum()), max(0f, bounds.h - e.vSum())))
        }
    }
    return n
}

fun makeAlign(alignment: Alignment2): KNode {
    val n = KNode("align")
    n.state = alignment
    n.measurer = { node, c ->
        var size = Size2()
        if (node.children.isNotEmpty()) {
            val cs = node.children[0].measure(c.loosen())
            size = Size2(if (c.maxW.isFinite()) c.maxW else cs.w,
                if (c.maxH.isFinite()) c.maxH else cs.h)
        }
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        if (node.children.isNotEmpty()) {
            val child = node.children[0]
            val cs = child.measure(Constraints2(0f, bounds.w, 0f, bounds.h))
            child.layout(alignment.mirrored(direction()).position(bounds, cs))
        }
    }
    return n
}

class ConstrainedOpts(val minW: Float, val minH: Float, val maxW: Float, val maxH: Float)

fun makeConstrainedBox(o: ConstrainedOpts): KNode {
    val n = KNode("constrained_box")
    n.state = o
    n.measurer = { node, c ->
        val add = Constraints2(o.minW, o.maxW, o.minH, o.maxH)
        val childC = c.enforcedBy(add)
        val size = if (node.children.isNotEmpty()) node.children[0].measure(childC)
            else Size2(childC.minW, childC.minH)
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        if (node.children.isNotEmpty()) node.children[0].layout(bounds)
    }
    return n
}

fun makeExpanded(weight: Int): KNode {
    val n = KNode("expanded")
    n.flex = max(1, weight)
    n.measurer = { node, c ->
        val size = if (node.children.isNotEmpty()) node.children[0].measure(c) else Size2()
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        if (node.children.isNotEmpty()) node.children[0].layout(bounds)
    }
    return n
}

// ---------------------------------------------------------------- container

class ContainerState(val color: Long?, val padding: EdgeInsets2)

fun makeContainer(color: Long?, padding: EdgeInsets2): KNode {
    val n = KNode("container")
    n.state = ContainerState(color, padding)
    n.measurer = { node, c ->
        val s = node.state as ContainerState
        val inner = c.deflateEdge(s.padding)
        var size = Size2()
        if (node.children.isNotEmpty()) {
            val cs = node.children[0].measure(inner)
            size = Size2(cs.w + s.padding.hSum(), cs.h + s.padding.vSum())
        }
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        if (node.children.isNotEmpty()) {
            val s = node.state as ContainerState
            node.children[0].layout(Rect2(
                bounds.x + s.padding.left, bounds.y + s.padding.top,
                max(0f, bounds.w - s.padding.hSum()), max(0f, bounds.h - s.padding.vSum())))
        }
    }
    n.paintFn = { node, sink ->
        val s = node.state as ContainerState
        s.color?.let { sink.fillRect(node.bounds.x, node.bounds.y, node.bounds.w, node.bounds.h, it) }
    }
    return n
}

// ---------------------------------------------------------------- text

class TextState(val text: String, val size: Float, val color: Long, val bold: Boolean, val align: TextAlign) {
    var metrics: TextMetrics = TextMeasure.measure(text, size, bold)
}

fun makeText(text: String, size: Float, color: Long, bold: Boolean, align: TextAlign): KNode {
    val n = KNode("text")
    val s = TextState(text, size, color, bold, align)
    n.state = s
    n.measurer = { _, c -> c.constrain(Size2(s.metrics.width, s.metrics.height)) }
    n.layouter = { _, _ -> }
    n.paintFn = { node, sink ->
        val resolved = resolveTextAlign(s.align, direction())
        val tx = when (resolved) {
            TextAlign.LEFT, TextAlign.START -> node.bounds.x
            TextAlign.CENTER -> node.bounds.x + (node.bounds.w - s.metrics.width) / 2
            TextAlign.RIGHT, TextAlign.END -> node.bounds.x + node.bounds.w - s.metrics.width
        }
        sink.text(s.text, tx, node.bounds.y + s.metrics.ascent, s.size, s.bold, s.color)
    }
    n.semantics = Semantics2().also { it.role = SemRole.TEXT; it.label = text }
    return n
}

// ---------------------------------------------------------------- l10n text

class L10nState(val engine: Engine, val key: String, val opts: L10nOpts) {
    var text = ""
    var countSig: KSignal<Long>? = null
    var count: Long = 0
    var isPlural = false
    var effect: Effect? = null
}

class L10nOpts(val size: Float = 14f, val color: Long = 0x000000FF, val bold: Boolean = false, val align: TextAlign = TextAlign.START)

private fun l10nResolve(s: L10nState) {
    val i18n = s.engine.i18n ?: return
    s.text = if (s.isPlural) {
        val n = s.countSig?.peek() ?: s.count
        i18n.trPlural(s.key, n, emptyMap())
    } else i18n.tr(s.key)
}

private fun l10nApplyText(n: KNode, s: L10nState) {
    n.semantics?.label = s.text
    n.markLayoutDirty()
    n.markDirty()
}

fun makeL10n(e: Engine, key: String, opts: L10nOpts): KNode {
    val n = KNode("l10n_text")
    val s = L10nState(e, key, opts)
    n.state = s
    wireL10n(n, s)
    s.effect = Effect {
        e.i18n?.localeSig?.get() // track locale
        l10nResolve(s)
        l10nApplyText(n, s)
    }
    s.effect!!.run()
    return n
}

fun makeL10nPlural(e: Engine, key: String, count: Long, sig: KSignal<Long>?, opts: L10nOpts): KNode {
    val n = KNode("l10n_plural")
    val s = L10nState(e, key, opts)
    s.isPlural = true
    s.count = count
    s.countSig = sig
    n.state = s
    wireL10n(n, s)
    s.effect = Effect {
        e.i18n?.localeSig?.get()
        sig?.get() // track count
        l10nResolve(s)
        l10nApplyText(n, s)
    }
    s.effect!!.run()
    if (sig != null) {
        // Mirror the reference: the count signal also drives re-resolution.
        sig.subscribe(Subscriber.ofCallback {
            l10nResolve(s)
            l10nApplyText(n, s)
        })
    }
    return n
}

private fun wireL10n(n: KNode, s: L10nState) {
    n.measurer = { _, c ->
        val m = TextMeasure.measure(s.text, s.opts.size, s.opts.bold)
        c.constrain(Size2(m.width, m.height))
    }
    n.layouter = { _, _ -> }
    n.paintFn = { node, sink ->
        val m = TextMeasure.measure(s.text, s.opts.size, s.opts.bold)
        val resolved = resolveTextAlign(s.opts.align, direction())
        val tx = when (resolved) {
            TextAlign.LEFT, TextAlign.START -> node.bounds.x
            TextAlign.CENTER -> node.bounds.x + (node.bounds.w - m.width) / 2
            TextAlign.RIGHT, TextAlign.END -> node.bounds.x + node.bounds.w - m.width
        }
        sink.text(s.text, tx, node.bounds.y + m.ascent, s.opts.size, s.opts.bold, s.opts.color)
    }
    n.semantics = Semantics2().also { it.role = SemRole.TEXT }
}

// ---------------------------------------------------------------- button

class ButtonState(val onPressed: (() -> Unit)?) {
    var pressed = false
    var hovered = false
    val pad = EdgeInsets2(16f, 8f, 16f, 8f)
    val radius = 8f
    val bg = 0x3B5BDBFFL; val bgHover = 0x4C6EF5FFL; val bgPressed = 0x364FC7FFL
}

fun makeButton(e: Engine, id: String): KNode {
    val n = KNode("button")
    val s = ButtonState(onPressed = { e.events.add("press:$id") })
    n.state = s
    n.measurer = { node, c ->
        var size = Size2(s.pad.hSum(), s.pad.vSum())
        if (node.children.isNotEmpty()) {
            val cs = node.children[0].measure(c.deflateEdge(s.pad))
            size = Size2(cs.w + s.pad.hSum(), cs.h + s.pad.vSum())
        }
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        if (node.children.isNotEmpty()) {
            node.children[0].layout(Rect2(
                bounds.x + s.pad.left, bounds.y + s.pad.top,
                max(0f, bounds.w - s.pad.hSum()), max(0f, bounds.h - s.pad.vSum())))
        }
    }
    n.paintFn = { node, sink ->
        val bg = if (s.pressed) s.bgPressed else if (s.hovered) s.bgHover else s.bg
        sink.fillRRect(node.bounds.x, node.bounds.y, node.bounds.w, node.bounds.h, s.radius, bg)
    }
    n.pointerHandler = { node, ev ->
        when (ev.phase) {
            PointerPhase.DOWN -> { s.pressed = true; node.markDirty(); true }
            PointerPhase.UP -> {
                s.pressed = false
                node.markDirty()
                if (node.bounds.contains(ev.x, ev.y)) s.onPressed?.invoke()
                true
            }
            PointerPhase.ENTER -> { s.hovered = true; node.markDirty(); true }
            PointerPhase.LEAVE -> { s.hovered = false; node.markDirty(); true }
            else -> false
        }
    }
    n.semantics = Semantics2().also {
        it.role = SemRole.BUTTON; it.focusable = true; it.actions = Actions2.one("activate")
    }
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

// ---------------------------------------------------------------- toggle

class ToggleState(val sig: KSignal<Boolean>, val onChanged: (() -> Unit)?) {
    val width = 44f; val height = 24f
    val trackOff = 0x444455FFL; val trackOn = 0x3B5BDBFFL; val knob = 0xFFFFFFFFL
}

fun makeToggle(e: Engine, id: String, sig: KSignal<Boolean>): KNode {
    val n = KNode("toggle")
    val s = ToggleState(sig, onChanged = { e.events.add("change:$id") })
    n.state = s
    n.measurer = { _, c -> c.constrain(Size2(s.width, s.height)) }
    n.layouter = { _, _ -> }
    n.paintFn = { node, sink ->
        val on = sig.get()
        val b = node.bounds
        sink.fillRRect(b.x, b.y, b.w, b.h, b.h / 2, if (on) s.trackOn else s.trackOff)
        val knobSize = b.h - 4
        val knobX = if (on) b.x + b.w - knobSize - 2 else b.x + 2
        sink.fillRRect(knobX, b.y + 2, knobSize, knobSize, knobSize / 2, s.knob)
    }
    n.pointerHandler = { node, ev ->
        when (ev.phase) {
            PointerPhase.UP -> {
                if (node.bounds.contains(ev.x, ev.y)) {
                    sig.set(!sig.get())
                    s.onChanged?.invoke()
                }
                true
            }
            PointerPhase.DOWN -> true
            else -> false
        }
    }
    n.semantics = Semantics2().also {
        it.role = SemRole.TOGGLE; it.focusable = true; it.checked = sig.peek()
        it.actions = Actions2.one("activate")
    }
    sig.subscribe(Subscriber.ofCallback {
        n.semantics?.checked = sig.peek()
        n.markDirty()
        e.a11y.controlChanged(n)
    })
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

// ---------------------------------------------------------------- checkbox

class CheckboxState(val sig: KSignal<Boolean>, val onChanged: (() -> Unit)?) {
    val size = 20f
    val boxColor = 0x282838FFL; val border = 0x555566FFL
    val check = 0xFFFFFFFFL; val accent = 0x3B5BDBFFL; val radius = 4f
}

fun makeCheckbox(e: Engine, id: String, sig: KSignal<Boolean>): KNode {
    val n = KNode("checkbox")
    val s = CheckboxState(sig, onChanged = { e.events.add("change:$id") })
    n.state = s
    n.measurer = { _, c -> c.constrain(Size2(s.size, s.size)) }
    n.layouter = { _, _ -> }
    n.paintFn = { node, sink ->
        val b = node.bounds
        if (sig.get()) {
            sink.fillRRect(b.x, b.y, b.w, b.h, s.radius, s.accent)
            val glyph = "✓"
            val gm = TextMeasure.measure(glyph, b.h * 0.7f, false)
            sink.text(glyph, b.x + (b.w - gm.width) / 2,
                b.y + (b.h - gm.height) / 2 + gm.ascent, b.h * 0.7f, false, s.check)
        } else {
            sink.fillRRect(b.x, b.y, b.w, b.h, s.radius, s.border)
            sink.fillRRect(b.x + 2, b.y + 2, b.w - 4, b.h - 4, max(0f, s.radius - 2), s.boxColor)
        }
    }
    n.pointerHandler = { node, ev ->
        when (ev.phase) {
            PointerPhase.UP -> {
                if (node.bounds.contains(ev.x, ev.y)) {
                    sig.set(!sig.get())
                    s.onChanged?.invoke()
                }
                true
            }
            PointerPhase.DOWN -> true
            else -> false
        }
    }
    n.semantics = Semantics2().also {
        it.role = SemRole.CHECKBOX; it.focusable = true; it.checked = sig.peek()
        it.actions = Actions2.one("activate")
    }
    sig.subscribe(Subscriber.ofCallback {
        n.semantics?.checked = sig.peek()
        n.markDirty()
        e.a11y.controlChanged(n)
    })
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

// ---------------------------------------------------------------- slider

class SliderState(val sig: KSignal<Float>, val onChanged: (() -> Unit)?, val defaultWidth: Float) {
    val height = 24f
    val track = 0x444455FFL; val fill = 0x3B5BDBFFL; val knob = 0xFFFFFFFFL
    val knobSize = 16f
}

fun makeSlider(e: Engine, id: String, sig: KSignal<Float>, defaultWidth: Float): KNode {
    val n = KNode("slider")
    val s = SliderState(sig, onChanged = { e.events.add("change:$id") }, defaultWidth)
    n.state = s
    n.measurer = { _, c ->
        val w = if (c.maxW.isFinite()) c.maxW else s.defaultWidth
        c.constrain(Size2(w, s.height))
    }
    n.layouter = { _, _ -> }
    n.paintFn = { node, sink ->
        val v = sig.get().coerceIn(0f, 1f)
        val b = node.bounds
        val trackH = 4f
        val ty = b.y + (b.h - trackH) / 2
        sink.fillRRect(b.x, ty, b.w, trackH, trackH / 2, s.track)
        sink.fillRRect(b.x, ty, b.w * v, trackH, trackH / 2, s.fill)
        val ks = s.knobSize
        sink.fillRRect(b.x + b.w * v - ks / 2, b.y + (b.h - ks) / 2, ks, ks, ks / 2, s.knob)
    }
    n.pointerHandler = { node, ev ->
        when (ev.phase) {
            PointerPhase.DOWN, PointerPhase.MOVE -> {
                val b = node.bounds
                if (b.w > 0) {
                    sig.set(((ev.x - b.x) / b.w).coerceIn(0f, 1f))
                    s.onChanged?.invoke()
                }
                true
            }
            PointerPhase.UP -> true
            else -> false
        }
    }
    n.keyHandler = { _, ev ->
        if (ev.kind != KeyEv.Kind.KEY_DOWN) false else {
            val step = 0.05f
            when (ev.key) {
                KKey.LEFT, KKey.DOWN -> {
                    sig.set((sig.peek() - step).coerceIn(0f, 1f)); s.onChanged?.invoke(); true
                }
                KKey.RIGHT, KKey.UP -> {
                    sig.set((sig.peek() + step).coerceIn(0f, 1f)); s.onChanged?.invoke(); true
                }
                else -> false
            }
        }
    }
    n.semantics = Semantics2().also {
        it.role = SemRole.SLIDER; it.focusable = true; it.actions = Actions2.incDec()
    }
    fun syncValue() {
        val pct = (sig.peek().coerceIn(0f, 1f) * 100).roundToInt()
        n.semantics?.value = "$pct%"
        n.markDirty()
        e.a11y.controlChanged(n)
    }
    sig.subscribe(Subscriber.ofCallback { syncValue() })
    // The reference calls the sync cb once at build — including the
    // control_changed bridge event (it lands in the a11y log pre-layout).
    syncValue()
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

// ---------------------------------------------------------------- text field

class TextFieldState(val onChanged: (() -> Unit)?, val onSubmitted: (() -> Unit)?) {
    val buf = StringBuilder()
    var placeholder = ""
    val size = 16f
    val color = 0xFFFFFFFFL; val hintColor = 0x888899FFL; val bg = 0x282838FFL
    val radius = 6f
    val pad = EdgeInsets2(8f, 6f, 8f, 6f)
    fun text() = buf.toString()
}

fun makeTextField(e: Engine, id: String, placeholder: String, initial: String): KNode {
    if (initial.length > TextSignal.MAX_LEN) throw ConfError("TextTooLong")
    val n = KNode("text_field")
    val s = TextFieldState(
        onChanged = { e.events.add("change:$id") },
        onSubmitted = { e.events.add("submit:$id") })
    s.placeholder = placeholder
    s.buf.append(initial)
    n.state = s
    n.measurer = { _, c ->
        val str = if (s.buf.isNotEmpty()) s.text() else s.placeholder
        val m = TextMeasure.measure(str, s.size, false)
        c.constrain(Size2(m.width + s.pad.hSum() + 2, m.height + s.pad.vSum()))
    }
    n.layouter = { _, _ -> }
    n.paintFn = { node, sink ->
        val b = node.bounds
        sink.fillRRect(b.x, b.y, b.w, b.h, s.radius, s.bg)
        val empty = s.buf.isEmpty()
        val str = if (empty) s.placeholder else s.text()
        val m = TextMeasure.measure(str, s.size, false)
        val textX = b.x + s.pad.left
        val textY = b.y + (b.h - m.height) / 2 + m.ascent
        if (str.isNotEmpty()) sink.text(str, textX, textY, s.size, false, if (empty) s.hintColor else s.color)
        if (e.router.isFocused(node)) {
            val cursorX = textX + (if (empty) 0f else m.width + 1)
            sink.fillRect(cursorX, b.y + s.pad.top, 2f, m.height, s.color)
        }
    }
    n.pointerHandler = { node, ev ->
        when (ev.phase) {
            PointerPhase.DOWN -> { e.router.requestFocus(node); node.markDirty(); true }
            PointerPhase.UP -> true
            else -> false
        }
    }
    n.keyHandler = { node, ev ->
        when (ev.kind) {
            KeyEv.Kind.TEXT_INPUT -> {
                if (s.buf.length + ev.text.length > TextSignal.MAX_LEN) true
                else {
                    s.buf.append(ev.text)
                    node.markDirty()
                    node.semantics?.value = s.text()
                    s.onChanged?.invoke()
                    true
                }
            }
            KeyEv.Kind.KEY_DOWN -> when (ev.key) {
                KKey.BACKSPACE -> {
                    if (s.buf.isNotEmpty()) {
                        // Drop the last codepoint (surrogate pair halves too).
                        s.buf.deleteCharAt(s.buf.length - 1)
                        if (s.buf.isNotEmpty() && s.buf[s.buf.length - 1].isHighSurrogate())
                            s.buf.deleteCharAt(s.buf.length - 1)
                    }
                    node.markDirty()
                    node.semantics?.value = s.text()
                    s.onChanged?.invoke()
                    true
                }
                KKey.ENTER -> { s.onSubmitted?.invoke(); true }
                KKey.ESCAPE -> { e.router.requestFocus(null); node.markDirty(); true }
                else -> false
            }
        }
    }
    n.semantics = Semantics2().also {
        it.role = SemRole.TEXT_FIELD; it.focusable = true
        it.hint = placeholder; it.value = s.text()
    }
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

private fun Char.isHighSurrogate() = this.code in 0xD800..0xDBFF

// ---------------------------------------------------------------- scroll view

class ScrollViewState(val wheelSpeed: Float = 48f) {
    val scroll = ScrollState2()
    val input = ScrollInput()
    var contentH = 0f
}

/** Drag-to-scroll + wheel input, shared by ScrollView and ListView
 *  (port of widgets/scroll_util.zig ScrollInput). */
class ScrollInput {
    private class Track(var pointer: Int = 0, var y: Float = 0f, var active: Boolean = false)
    private val tracks = Array(MAX_TRACKS) { Track() }

    private fun trackFor(pointer: Int): Track {
        for (t in tracks) if (t.active && t.pointer == pointer) return t
        for (t in tracks) if (!t.active) return t
        return tracks[0]
    }
    private fun releaseTrack(pointer: Int) {
        for (t in tracks) if (t.active && t.pointer == pointer) t.active = false
    }

    fun onPointer(ev: PointerEv, scroll: ScrollState2, setOffset: (Float) -> Boolean): Boolean {
        when (ev.phase) {
            PointerPhase.DOWN -> {
                val t = trackFor(ev.pointer)
                t.pointer = ev.pointer; t.y = ev.rawY; t.active = true
                return false // items handle taps
            }
            PointerPhase.UP, PointerPhase.OUTSIDE_DOWN -> { releaseTrack(ev.pointer); return false }
            PointerPhase.MOVE -> {}
            else -> return false
        }
        val router = Engine.current?.router ?: return false
        val dragging = router.capturedNode(ev.pointer) != null
        val t = trackFor(ev.pointer)
        val last = if (t.active && t.pointer == ev.pointer) t.y else ev.rawY
        t.pointer = ev.pointer; t.y = ev.rawY; t.active = true
        if (!dragging) return false
        val dy = ev.rawY - last
        if (dy == 0f) return false
        return setOffset(scroll.offset - dy)
    }

    fun onScroll(ev: ScrollEv, scroll: ScrollState2, wheelSpeed: Float, setOffset: (Float) -> Boolean): Boolean {
        if (!scroll.info().canScroll()) return false
        return setOffset(scroll.offset - ev.deltaY * wheelSpeed)
    }

    companion object { const val MAX_TRACKS = 8 }
}

fun makeScrollView(e: Engine, wheelSpeed: Float): KNode {
    val n = KNode("scroll_view")
    val s = ScrollViewState(wheelSpeed)
    n.state = s
    n.measurer = { node, c ->
        if (node.children.isNotEmpty()) {
            val childC = Constraints2(0f, c.maxW, 0f, Float.POSITIVE_INFINITY)
            val cs = node.children[0].measure(childC)
            s.contentH = cs.h
            s.scroll.content = cs.h
        }
        c.constrain(Size2(c.maxW, c.maxH))
    }
    n.layouter = { node, bounds ->
        s.scroll.viewport = bounds.h
        if (node.children.isNotEmpty()) {
            val childC = Constraints2(0f, bounds.w, 0f, Float.POSITIVE_INFINITY)
            val cs = node.children[0].measure(childC)
            s.contentH = cs.h
            s.scroll.content = cs.h
            s.scroll.setOffset(s.scroll.offset)
            node.children[0].layout(Rect2(bounds.x, bounds.y, bounds.w, max(cs.h, bounds.h)))
        }
    }
    n.preChildrenHit = { node, px, py ->
        val st = node.state as ScrollViewState
        px to py + st.scroll.offset
    }
    n.mapPaintRect = { node, r ->
        val st = node.state as ScrollViewState
        Rect2(r.x, r.y - st.scroll.offset, r.w, r.h)
    }
    n.childClip = { node -> node.bounds }
    n.pointerHandler = { node, ev -> s.input.onPointer(ev, s.scroll) { v -> setScrollOffset(node, v) } }
    n.scrollHandler = { node, ev -> s.input.onScroll(ev, s.scroll, s.wheelSpeed) { v -> setScrollOffset(node, v) } }
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

fun setScrollOffset(n: KNode, value: Float): Boolean {
    val s = n.state as? ScrollViewState ?: return setListScrollOffset(n, value)
    if (!s.scroll.setOffset(value)) return false
    n.markDirty()
    return true
}

fun scrollOffsetOf(n: KNode): Float = when (val s = n.state) {
    is ScrollViewState -> s.scroll.offset
    is ListViewState -> s.scroll.offset
    else -> 0f
}

fun scrollInfoOf(n: KNode): ScrollInfo? = when (val s = n.state) {
    is ScrollViewState -> s.scroll.info()
    is ListViewState -> s.scroll.info()
    else -> null
}

// ---------------------------------------------------------------- list view

class ListViewState(
    var itemCount: Int,
    val itemHeight: Float,
    val gap: Float,
    val margin: Int,
    val wheelSpeed: Float,
    val itemFocusable: Boolean,
    val itemPress: Boolean,
    val listId: String,
    val engine: Engine,
) {
    val scroll = ScrollState2()
    val input = ScrollInput()
    var first = 0
    fun stride() = itemHeight + gap
    fun contentHeight() = if (itemCount == 0) 0f else itemCount * stride() - gap
}

private fun listItemNode(s: ListViewState, index: Int): KNode {
    val e = s.engine
    val name = "${s.listId}.item$index"
    val palette = longArrayOf(0xFF0000FF, 0x00FF00FF, 0x0000FFFF)
    val n = makeBox(e, name, 0f, 0f, palette[index % 3], s.itemPress)
    (n.state as BoxState).itemIndex = index
    if (s.itemFocusable) {
        n.semantics = Semantics2().also { it.role = SemRole.LIST_ITEM; it.focusable = true }
    }
    e.ids[name] = n
    return n
}

private fun layoutItem(n: KNode, child: KNode, index: Int) {
    val s = n.state as ListViewState
    child.layout(Rect2(n.bounds.x, n.bounds.y + index * s.stride(), n.bounds.w, s.itemHeight))
}

/** The virtualization diff: children[0] is item `first`; the live window is
 *  [range.first, range.last) (port of scroll_util.syncItemWindow). */
fun syncItemWindow(n: KNode, s: ListViewState, range: IRange) {
    val oldLast = s.first + n.children.size
    val overlaps = s.first < range.last && range.first < oldLast
    if (!overlaps) {
        while (n.children.isNotEmpty()) {
            val child = n.children.last()
            n.remove(child)
            releaseIds(child, s.engine)
        }
        s.first = range.first
    }
    while (s.first < range.first) {
        if (n.children.isNotEmpty()) {
            val child = n.children[0]
            n.remove(child)
            releaseIds(child, s.engine)
        }
        s.first += 1
    }
    while (s.first + n.children.size > range.last && n.children.isNotEmpty()) {
        val child = n.children.last()
        n.remove(child)
        releaseIds(child, s.engine)
    }
    while (s.first > range.first) {
        s.first -= 1
        val child = listItemNode(s, s.first)
        n.insert(0, child)
        layoutItem(n, child, s.first)
    }
    while (s.first + n.children.size < range.last) {
        val index = s.first + n.children.size
        val child = listItemNode(s, index)
        n.add(child)
        layoutItem(n, child, index)
    }
}

fun releaseIds(n: KNode, e: Engine) {
    e.ids.entries.removeIf { it.value === n }
    e.router.releaseNode(n)
    Engine.current?.fm?.let { if (it.focused === n) it.focusNode(null) }
    n.deinitFn?.invoke(n)
    for (c in n.children.toList()) releaseIds(c, e)
}

fun makeListView(e: Engine, itemCount: Int, itemHeight: Float, gap: Float, margin: Int,
                 wheelSpeed: Float, itemFocusable: Boolean, itemPress: Boolean, listId: String): KNode {
    val n = KNode("list_view")
    val s = ListViewState(itemCount, itemHeight, gap, margin, wheelSpeed, itemFocusable, itemPress, listId, e)
    n.state = s
    n.measurer = { _, c -> c.constrain(Size2(c.maxW, c.maxH)) }
    n.layouter = { node, bounds ->
        s.scroll.viewport = bounds.h
        s.scroll.content = s.contentHeight()
        s.scroll.setOffset(s.scroll.offset)
        if (s.scroll.viewport > 0) {
            val range = visibleRange(s.itemCount, s.stride(), s.scroll.viewport, s.scroll.offset, s.margin)
            syncItemWindow(node, s, range)
        }
        for (i in node.children.indices) layoutItem(node, node.children[i], s.first + i)
    }
    n.preChildrenHit = { node, px, py ->
        val st = node.state as ListViewState
        px to py + st.scroll.offset
    }
    n.mapPaintRect = { node, r ->
        val st = node.state as ListViewState
        Rect2(r.x, r.y - st.scroll.offset, r.w, r.h)
    }
    n.childClip = { node -> node.bounds }
    n.pointerHandler = { node, ev -> s.input.onPointer(ev, s.scroll) { v -> setListScrollOffset(node, v) } }
    n.scrollHandler = { node, ev -> s.input.onScroll(ev, s.scroll, s.wheelSpeed) { v -> setListScrollOffset(node, v) } }
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

fun setListScrollOffset(n: KNode, value: Float): Boolean {
    val s = n.state as? ListViewState ?: return setScrollOffset(n, value)
    if (!s.scroll.setOffset(value)) return false
    if (s.scroll.viewport > 0) {
        val range = visibleRange(s.itemCount, s.stride(), s.scroll.viewport, s.scroll.offset, s.margin)
        syncItemWindow(n, s, range)
    }
    n.markDirty()
    return true
}

fun setListItemCount(n: KNode, count: Int) {
    val s = n.state as ListViewState
    s.itemCount = count
    s.scroll.content = s.contentHeight()
    s.scroll.setOffset(s.scroll.offset)
    reloadListItems(n)
}

fun reloadListItems(n: KNode) {
    val s = n.state as ListViewState
    while (n.children.isNotEmpty()) {
        val child = n.children.last()
        n.remove(child)
        releaseIds(child, s.engine)
    }
    if (s.scroll.viewport > 0) {
        val range = visibleRange(s.itemCount, s.stride(), s.scroll.viewport, s.scroll.offset, s.margin)
        s.first = range.first
        syncItemWindow(n, s, range)
    } else s.first = 0
    n.markLayoutDirty()
    n.markDirty()
}

// ---------------------------------------------------------------- gesture detector

fun makeGestureDetector(e: Engine, gestures: List<String>): KNode {
    val n = KNode("gesture_detector")
    val arena = GestureArena(gestures, e)
    n.state = arena
    n.measurer = { node, c ->
        // Fill semantics like Padding: the child's size is the detector's.
        var size = Size2()
        if (node.children.isNotEmpty()) size = node.children[0].measure(c)
        c.constrain(size)
    }
    n.layouter = { node, bounds ->
        if (node.children.isNotEmpty()) node.children[0].layout(bounds)
    }
    n.pointerHandler = { _, ev ->
        arena.feed(ev)
        true // the detector claims every pointer event on its surface
    }
    Engine.current?.timeline?.addTicker { now -> arena.tick(now) }
    n.deinitFn = { node -> e.router.releaseNode(node) }
    return n
}

// ---------------------------------------------------------------- prop semantics + builder

fun attachPropSemantics(node: KNode, props: JVal?) {
    val p = props?.obj ?: return
    if (!p.containsKey("role") && !p.containsKey("label") && !p.containsKey("focusable") &&
        !p.containsKey("checked") && !p.containsKey("disabled") && !p.containsKey("hint") &&
        !p.containsKey("value") && !p.containsKey("actions")) return
    val s = node.semantics ?: Semantics2().also { node.semantics = it }
    p["role"]?.strOr("")?.let { if (it.isNotEmpty()) s.role = parseRole(it) }
    p["label"]?.strOr("")?.let { if (it.isNotEmpty()) s.label = it }
    p["hint"]?.strOr("")?.let { if (it.isNotEmpty()) s.hint = it }
    p["value"]?.strOr("")?.let { if (it.isNotEmpty()) s.value = it }
    if (p.containsKey("checked")) s.checked = p["checked"].boolOr(false)
    if (p.containsKey("disabled")) s.disabled = p["disabled"].boolOr(false)
    if (p.containsKey("focusable")) s.focusable = p["focusable"].boolOr(false)
    (p["actions"]?.arr)?.forEach { av ->
        val name = av.strOr("")
        when (name) {
            "activate" -> s.actions.activate = true
            "increment" -> s.actions.increment = true
            "decrement" -> s.actions.decrement = true
            "delete" -> s.actions.delete = true
        }
    }
}

/** buildNode — mirrors conformance.zig exactly (type → widget constructor,
 *  node-level props afterwards). */
fun buildNode(e: Engine, tv: JVal): KNode {
    val wtype = tv.prop("type").strOr("") .ifEmpty { throw ConfError("MissingType") }
    val id = tv.prop("id").strOr("")
    val props = tv.prop("props")

    val node: KNode = when (wtype) {
        "box" -> makeBox(e, id, props.prop("w").numOf(0f), props.prop("h").numOf(0f),
            parseColorV(props.prop("color")) ?: 0xCCCCCCFF, props.prop("on_press").boolOr(false))
        "row", "column" -> makeFlex(
            if (wtype == "row") Axis.HORIZONTAL else Axis.VERTICAL,
            props.prop("gap").numOf(0f), props.prop("padding").numOf(0f),
            parseMainAlignV(props.prop("main_align").strOr("start")),
            parseCrossAlignV(props.prop("cross_align").strOr("stretch")))
        "stack" -> makeStack(
            if (props.prop("fit").strOr("loose") == "expand") StackFit.EXPAND else StackFit.LOOSE,
            parseAlignmentV(props.prop("alignment")) ?: Alignment2.TOP_LEFT)
        "grid" -> makeGrid(
            props.prop("columns").numOf(2f).toInt(),
            props.prop("gap").numOf(0f), props.prop("padding").numOf(0f))
        "padding" -> makePadding(parseInsetsV(props.prop("padding")) ?: EdgeInsets2())
        "padding_directional" -> makePaddingDir(parseDirInsetsV(props) ?: EdgeInsetsDir())
        "center" -> makeAlign(Alignment2.CENTER)
        "align" -> makeAlign(parseAlignmentV(props.prop("alignment")) ?: Alignment2.CENTER)
        "constrained_box" -> makeConstrainedBox(ConstrainedOpts(
            props.prop("min_w").numOf(0f), props.prop("min_h").numOf(0f),
            props.prop("max_w").numOf(Float.POSITIVE_INFINITY), props.prop("max_h").numOf(Float.POSITIVE_INFINITY)))
        "expanded" -> makeExpanded(props.prop("weight").numOf(1f).toInt())
        "container" -> makeContainer(parseColorV(props.prop("color")),
            parseInsetsV(props.prop("padding")) ?: EdgeInsets2())
        "text" -> makeText(props.prop("text").strOr(""), props.prop("size").numOf(16f),
            parseColorV(props.prop("color")) ?: 0x000000FF, props.prop("bold").boolOr(false),
            parseTextAlignV(props.prop("text_align").strOr("left")))
        "button" -> makeButton(e, id)
        "toggle" -> {
            val sig = e.sigBool(props.prop("signal").strOr(id), props.prop("checked").boolOr(false))
            makeToggle(e, id, sig)
        }
        "checkbox" -> {
            val sig = e.sigBool(props.prop("signal").strOr(id), props.prop("checked").boolOr(false))
            makeCheckbox(e, id, sig)
        }
        "slider" -> {
            val sig = e.sigFloat(props.prop("signal").strOr(id), props.prop("value").numOf(0.5f))
            makeSlider(e, id, sig, props.prop("width").numOf(200f))
        }
        "text_field" -> makeTextField(e, id,
            props.prop("placeholder").strOr(""), props.prop("initial").strOr(""))
        "gesture_detector" -> {
            val gs = mutableListOf<String>()
            props.prop("gestures")?.arr?.forEach { gs.add(it.strOr("")) }
            makeGestureDetector(e, gs)
        }
        "scroll_view" -> {
            val n = makeScrollView(e, props.prop("wheel_speed").numOf(48f))
            if (id.isNotEmpty()) e.scrollKind[id] = "view"
            n
        }
        "list_view" -> {
            val listId = if (id.isNotEmpty()) id else "list"
            val n = makeListView(e,
                props.prop("item_count").numOf(0f).toInt(),
                props.prop("item_height").numOf(48f),
                props.prop("gap").numOf(0f),
                props.prop("margin").numOf(2f).toInt(),
                props.prop("wheel_speed").numOf(48f),
                props.prop("item_focusable").boolOr(false),
                props.prop("item_press").boolOr(false),
                listId)
            if (id.isNotEmpty()) e.scrollKind[id] = "list"
            n
        }
        "l10n_text" -> {
            val i18n = e.i18n ?: throw ConfError("MissingI18n")
            makeL10n(e, props.prop("key").strOr(""), L10nOpts(size = props.prop("size").numOf(14f)))
        }
        "l10n_plural" -> {
            val i18n = e.i18n ?: throw ConfError("MissingI18n")
            val sigName = props.prop("count_signal")?.str
            val sig = sigName?.let { e.sigInt(it, props.prop("count").intOf(0)) }
            makeL10nPlural(e, props.prop("key").strOr(""), props.prop("count").intOf(0), sig, L10nOpts())
        }
        else -> throw ConfError("UnknownType")
    }

    // children
    tv.prop("children")?.arr?.forEach { kv -> node.add(buildNode(e, kv)) }

    // node-level props (applyNodeProps)
    props?.obj?.let { p ->
        p["flex"]?.let { node.flex = max(0, it.numOr(1f).toInt()) }
        p["visible"]?.let { node.visible = it.boolOr(true) }
        parseRectV(p["damage_overflow"])?.let { r ->
            node.damageOverflow = EdgeInsets2(r.x, r.y, r.w, r.h)
        }
        if (p["exclude_semantics"].boolOr(false)) node.excludeSemantics = true
        attachPropSemantics(node, props)
    }
    if (id.isNotEmpty()) {
        if (e.ids.containsKey(id)) throw ConfError("DuplicateId")
        node.id = id
        e.ids[id] = node
    }
    return node
}
