// Core model — a Kotlin port of src/ui/node.zig, src/ui/layout.zig,
// src/ui/input.zig, src/ui/semantics.zig, src/ui/scroll.zig and the
// src/ui/anim.zig timeline ticker.
//
// Architecture (see MAPPING.md): the adapter keeps a semantic node model
// (KNode) that is a faithful port of the reference retained tree. The same
// model drives a real Compose scene — every KNode is emitted as a Compose
// `Layout` composable whose MeasurePolicy delegates to the ported
// measure/layout algorithm, whose draw modifier replays the node's paint
// ops onto a real Skiko surface, and whose semantics modifier projects the
// node's Semantics record into the real Compose semantics tree. Pixels and
// the a11y tree are read back from the real Compose pipeline; rects are the
// same coordinates Compose placed (the policies place at model bounds).
package conf.compose

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Conformance error — carries the reference error name ("UnknownRoute",
 *  "TextTooLong", ...). Action ops translate it into `action_error`. */
class ConfError(val code: String) : Exception(code)

/** The currently-running effect (dependency tracking), like the reference's
 *  global current-effect slot. Single-threaded runner. */
object Harness {
    var currentEffect: Effect? = null
}

// ---------------------------------------------------------------- geometry

enum class Axis { HORIZONTAL, VERTICAL }
enum class Direction { LTR, RTL }
enum class MainAlign { START, CENTER, END, SPACE_BETWEEN, SPACE_AROUND, SPACE_EVENLY }
enum class CrossAlign { START, CENTER, END, STRETCH }
enum class TextAlign { LEFT, CENTER, RIGHT, START, END }

fun resolveTextAlign(a: TextAlign, dir: Direction): TextAlign = when (a) {
    TextAlign.START -> if (dir == Direction.RTL) TextAlign.RIGHT else TextAlign.LEFT
    TextAlign.END -> if (dir == Direction.RTL) TextAlign.LEFT else TextAlign.RIGHT
    else -> a
}

data class Size2(val w: Float = 0f, val h: Float = 0f) {
    fun main(axis: Axis) = if (axis == Axis.HORIZONTAL) w else h
    fun cross(axis: Axis) = if (axis == Axis.HORIZONTAL) h else w
    companion object {
        fun fromMainCross(axis: Axis, m: Float, c: Float) =
            if (axis == Axis.HORIZONTAL) Size2(m, c) else Size2(c, m)
    }
}

data class Rect2(var x: Float = 0f, var y: Float = 0f, var w: Float = 0f, var h: Float = 0f) {
    fun right() = x + w
    fun bottom() = y + h
    fun contains(px: Float, py: Float) = px >= x && px < right() && py >= y && py < bottom()
    fun intersects(o: Rect2) = o.x < right() && x < o.right() && o.y < bottom() && y < o.bottom()
    fun union(o: Rect2): Rect2 {
        if (w <= 0 || h <= 0) return o.copy()
        if (o.w <= 0 || o.h <= 0) return copy()
        val nx = min(x, o.x); val ny = min(y, o.y)
        return Rect2(nx, ny, max(right(), o.right()) - nx, max(bottom(), o.bottom()) - ny)
    }
    fun intersection(o: Rect2): Rect2 {
        val nx = max(x, o.x); val ny = max(y, o.y)
        val nr = min(right(), o.right()); val nb = min(bottom(), o.bottom())
        return if (nr > nx && nb > ny) Rect2(nx, ny, nr - nx, nb - ny) else Rect2()
    }
    fun isEmpty() = w <= 0 || h <= 0
    fun set(o: Rect2) { x = o.x; y = o.y; w = o.w; h = o.h }
}

data class Constraints2(
    var minW: Float = 0f, var maxW: Float = Float.POSITIVE_INFINITY,
    var minH: Float = 0f, var maxH: Float = Float.POSITIVE_INFINITY,
) {
    fun constrain(s: Size2) = Size2(s.w.coerceIn(minW, maxW), s.h.coerceIn(minH, maxH))
    fun deflate(amount: Float) = Constraints2(
        max(0f, minW - amount), max(0f, maxW - amount),
        max(0f, minH - amount), max(0f, maxH - amount))
    fun deflateEdge(e: EdgeInsets2) = Constraints2(
        max(0f, minW - e.hSum()), max(0f, maxW - e.hSum()),
        max(0f, minH - e.vSum()), max(0f, maxH - e.vSum()))
    fun enforcedBy(add: Constraints2) = Constraints2(
        add.minW.coerceIn(minW, maxW), add.maxW.coerceIn(minW, maxW),
        add.minH.coerceIn(minH, maxH), add.maxH.coerceIn(minH, maxH))
    fun loosenMain(axis: Axis) = if (axis == Axis.HORIZONTAL)
        Constraints2(0f, maxW, minH, maxH) else Constraints2(minW, maxW, 0f, maxH)
    fun loosen() = Constraints2(0f, maxW, 0f, maxH)
}

data class EdgeInsets2(val left: Float = 0f, val top: Float = 0f, val right: Float = 0f, val bottom: Float = 0f) {
    fun hSum() = left + right
    fun vSum() = top + bottom
    companion object {
        fun all(v: Float) = EdgeInsets2(v, v, v, v)
        fun symmetric(h: Float, v: Float) = EdgeInsets2(h, v, h, v)
    }
}

data class EdgeInsetsDir(val start: Float = 0f, val end: Float = 0f, val top: Float = 0f, val bottom: Float = 0f) {
    fun resolve(dir: Direction) = if (dir == Direction.LTR)
        EdgeInsets2(start, top, end, bottom) else EdgeInsets2(end, top, start, bottom)
    companion object { fun all(v: Float) = EdgeInsetsDir(v, v, v, v) }
}

data class Alignment2(val x: Float = 0f, val y: Float = 0f) {
    fun position(bounds: Rect2, s: Size2) = Rect2(
        bounds.x + (bounds.w - s.w) * (x + 1) / 2,
        bounds.y + (bounds.h - s.h) * (y + 1) / 2, s.w, s.h)
    fun mirrored(dir: Direction) = if (dir == Direction.LTR) this else Alignment2(-x, y)
    companion object {
        val TOP_LEFT = Alignment2(-1f, -1f); val TOP_CENTER = Alignment2(0f, -1f)
        val TOP_RIGHT = Alignment2(1f, -1f); val CENTER_LEFT = Alignment2(-1f, 0f)
        val CENTER = Alignment2(0f, 0f); val CENTER_RIGHT = Alignment2(1f, 0f)
        val BOTTOM_LEFT = Alignment2(-1f, 1f); val BOTTOM_CENTER = Alignment2(0f, 1f)
        val BOTTOM_RIGHT = Alignment2(1f, 1f)
    }
}

// ---------------------------------------------------------------- semantics

/** Roles — a superset of the reference enum (kept as strings at the JSON
 *  boundary; parseRole accepts every reference role name). */
enum class SemRole { NONE, TEXT, HEADING, BUTTON, LINK, IMAGE, TEXT_FIELD,
    TOGGLE, CHECKBOX, RADIO, SLIDER, PROGRESS, SCROLLBAR, LIST, LIST_ITEM,
    DIALOG, ALERT, MENU, MENU_ITEM, TAB, TAB_PANEL, SEPARATOR, GROUP }

fun parseRole(s: String): SemRole = when (s) {
    "text" -> SemRole.TEXT; "heading" -> SemRole.HEADING; "button" -> SemRole.BUTTON
    "link" -> SemRole.LINK; "image" -> SemRole.IMAGE; "text_field" -> SemRole.TEXT_FIELD
    "toggle" -> SemRole.TOGGLE; "checkbox" -> SemRole.CHECKBOX; "radio" -> SemRole.RADIO
    "slider" -> SemRole.SLIDER; "progress" -> SemRole.PROGRESS; "scrollbar" -> SemRole.SCROLLBAR
    "list" -> SemRole.LIST; "list_item" -> SemRole.LIST_ITEM; "dialog" -> SemRole.DIALOG
    "alert" -> SemRole.ALERT; "menu" -> SemRole.MENU; "menu_item" -> SemRole.MENU_ITEM
    "tab" -> SemRole.TAB; "tab_panel" -> SemRole.TAB_PANEL; "separator" -> SemRole.SEPARATOR
    "group" -> SemRole.GROUP; else -> SemRole.NONE
}

fun roleName(r: SemRole): String = when (r) {
    SemRole.NONE -> "none"; SemRole.TEXT -> "text"; SemRole.HEADING -> "heading"
    SemRole.BUTTON -> "button"; SemRole.LINK -> "link"; SemRole.IMAGE -> "image"
    SemRole.TEXT_FIELD -> "text_field"; SemRole.TOGGLE -> "toggle"; SemRole.CHECKBOX -> "checkbox"
    SemRole.RADIO -> "radio"; SemRole.SLIDER -> "slider"; SemRole.PROGRESS -> "progress"
    SemRole.SCROLLBAR -> "scrollbar"; SemRole.LIST -> "list"; SemRole.LIST_ITEM -> "list_item"
    SemRole.DIALOG -> "dialog"; SemRole.ALERT -> "alert"; SemRole.MENU -> "menu"
    SemRole.MENU_ITEM -> "menu_item"; SemRole.TAB -> "tab"; SemRole.TAB_PANEL -> "tab_panel"
    SemRole.SEPARATOR -> "separator"; SemRole.GROUP -> "group"
}

class Actions2 {
    var activate = false; var increment = false; var decrement = false; var delete = false
    fun contains(name: String) = when (name) {
        "activate" -> activate; "increment" -> increment
        "decrement" -> decrement; "delete" -> delete; else -> false
    }
    fun copy() = Actions2().also {
        it.activate = activate; it.increment = increment; it.decrement = decrement; it.delete = delete
    }
    companion object {
        fun one(name: String) = Actions2().also { a -> when (name) {
            "activate" -> a.activate = true; "increment" -> a.increment = true
            "decrement" -> a.decrement = true; "delete" -> a.delete = true } }
        fun incDec() = Actions2().also { it.increment = true; it.decrement = true }
    }
}

class Semantics2 {
    var role: SemRole = SemRole.NONE
    var label = ""
    var hint = ""
    var value = ""
    var checked: Boolean? = null
    var disabled = false
    var focusable = false
    var actions: Actions2 = Actions2()
    fun copy() = Semantics2().also {
        it.role = role; it.label = label; it.hint = hint; it.value = value
        it.checked = checked; it.disabled = disabled; it.focusable = focusable
        it.actions = actions.copy()
    }
}

// ---------------------------------------------------------------- input events

enum class PointerPhase { DOWN, MOVE, UP, ENTER, LEAVE, OUTSIDE_DOWN, HOVER_MOVE }

class PointerEv(
    val phase: PointerPhase,
    var x: Float = 0f, var y: Float = 0f,       // delivered coords (hit node's parent space)
    var rawX: Float = 0f, var rawY: Float = 0f, // window coords — drag deltas use these
    val pointer: Int = 0,
    var timeMs: Long = 0,
)

class ScrollEv(
    var x: Float = 0f, var y: Float = 0f,
    var deltaX: Float = 0f, var deltaY: Float = 0f,
    val pointer: Int = 0, var timeMs: Long = 0,
)

/** Platform keys (subset of the reference enum + char codepoints). */
enum class KKey { UNKNOWN, BACKSPACE, TAB, ENTER, ESCAPE, DELETE, LEFT, RIGHT, BACK, UP, DOWN, SPACE, CHAR }
class KeyEv(val kind: Kind, val key: KKey = KKey.UNKNOWN, val text: String = "", val shift: Boolean = false, val char: Char = ' ') {
    enum class Kind { KEY_DOWN, TEXT_INPUT }
}

fun parseKeyName(s: String): Pair<KKey, Char> = when (s) {
    "tab" -> KKey.TAB to ' '; "enter" -> KKey.ENTER to ' '; "space" -> KKey.SPACE to ' '
    "escape" -> KKey.ESCAPE to ' '; "backspace" -> KKey.BACKSPACE to ' '; "delete" -> KKey.DELETE to ' '
    "left" -> KKey.LEFT to ' '; "right" -> KKey.RIGHT to ' '; "up" -> KKey.UP to ' '
    "down" -> KKey.DOWN to ' '; "back" -> KKey.BACK to ' '
    else -> if (s.length == 1) KKey.CHAR to s[0] else KKey.UNKNOWN to ' '
}

// ---------------------------------------------------------------- KNode

typealias MeasureFn = (KNode, Constraints2) -> Size2
typealias LayoutFn = (KNode, Rect2) -> Unit
typealias PointerFn = (KNode, PointerEv) -> Boolean
typealias KeyFn = (KNode, KeyEv) -> Boolean
typealias ScrollFn = (KNode, ScrollEv) -> Boolean
typealias MapPaintRectFn = (KNode, Rect2) -> Rect2
typealias HitPointFn = (KNode, Float, Float) -> Pair<Float, Float>

class KNode(val kind: String) {
    var parent: KNode? = null
    val children = mutableListOf<KNode>()
    var bounds = Rect2()          // in the PARENT's coordinate space (scroll children: content space)
    var flex = 0
    var visible = true
    var excludeSemantics = false
    var semantics: Semantics2? = null
    var state: Any? = null
    var damageOverflow = EdgeInsets2()
    var layoutDirty = true
    var id = ""

    var measurer: MeasureFn? = null
    var layouter: LayoutFn? = null
    var pointerHandler: PointerFn? = null
    var keyHandler: KeyFn? = null
    var scrollHandler: ScrollFn? = null
    var mapPaintRect: MapPaintRectFn? = null   // parent-space rect → visual (scroll: -offset)
    var preChildrenHit: HitPointFn? = null     // parent-space point → content space
    var childClip: ((KNode) -> Rect2)? = null  // viewport clip for the children pass
    var paintFn: ((KNode, PaintSink) -> Unit)? = null
    var deinitFn: ((KNode) -> Unit)? = null

    fun add(child: KNode) {
        child.parent?.remove(child)
        child.parent = this
        children.add(child)
        markLayoutDirty()
    }
    fun insert(index: Int, child: KNode) {
        child.parent?.remove(child)
        child.parent = this
        children.add(index.coerceIn(0, children.size), child)
        markLayoutDirty()
    }
    fun remove(child: KNode): Boolean {
        val i = children.indexOf(child)
        if (i < 0) return false
        children.removeAt(i)
        child.parent = null
        markLayoutDirty()
        return true
    }

    fun measure(c: Constraints2): Size2 = measurer?.invoke(this, c) ?: c.constrain(Size2())

    fun layout(b: Rect2) {
        bounds = b
        layoutDirty = false
        layouter?.invoke(this, b)
    }

    /** Own paint extent in the PARENT's space: bounds + damage_overflow. */
    fun paintRect(): Rect2 {
        val o = damageOverflow
        return Rect2(bounds.x - o.left, bounds.y - o.top,
            bounds.w + o.left + o.right, bounds.h + o.top + o.bottom)
    }

    fun markDirty() { Engine.current?.let { markDirtyUp(); damageRectUp(paintRect(), it) } }
    fun markDirtyRect(r: Rect2) { Engine.current?.let { markDirtyUp(); damageRectUp(r, it) } }
    fun markLayoutDirty() { layoutDirty = true; parent?.markLayoutDirty(); markDirty() }

    private fun markDirtyUp() { var n: KNode? = this; while (n != null) { n = n.parent } }

    private fun damageRectUp(rect: Rect2, e: Engine) {
        var r = rect
        var n: KNode? = this
        while (n?.parent != null) {
            val p = n!!.parent!!
            p.mapPaintRect?.let { r = it(p, r) }
            n = p
        }
        e.unionDamage(r)
    }

    /** Map a rect (in this node's parent space) to the root — through every
     *  strict ancestor's map_paint_rect. */
    fun mapRectToRoot(rect: Rect2): Rect2 {
        var r = rect
        var n: KNode? = this
        while (n?.parent != null) {
            val p = n!!.parent!!
            p.mapPaintRect?.let { r = it(p, r) }
            n = p
        }
        return r
    }

    /** Map a window point into this node's parent space (strict ancestors'
     *  pre_children_hit, root-first). */
    fun mapPointToParentSpace(px: Float, py: Float): Pair<Float, Float> {
        val chain = ArrayList<KNode>()
        var n = parent
        while (n != null) { chain.add(n); n = n.parent }
        var x = px; var y = py
        for (i in chain.size - 1 downTo 0) {
            chain[i].preChildrenHit?.let { val p = it(chain[i], x, y); x = p.first; y = p.second }
        }
        return x to y
    }

    // --- hit testing -------------------------------------------------------

    /** Deepest visible node whose bounds contain the point. Each node sees
     *  the point in its own space; scroll containers remap for children. */
    fun hitTest(px: Float, py: Float): KNode? {
        if (!visible) return null
        if (!bounds.contains(px, py)) return null
        var cx = px; var cy = py
        preChildrenHit?.let { val p = it(this, px, py); cx = p.first; cy = p.second }
        for (i in children.size - 1 downTo 0) {
            children[i].hitTest(cx, cy)?.let { return it }
        }
        return this
    }

    class MappedHit(val node: KNode, val x: Float, val y: Float)

    /** Hit-test returning the point in the hit node's parent space. */
    fun hitTestMapped(px: Float, py: Float): MappedHit? {
        if (!visible) return null
        if (!bounds.contains(px, py)) return null
        var cx = px; var cy = py
        preChildrenHit?.let { val p = it(this, px, py); cx = p.first; cy = p.second }
        for (i in children.size - 1 downTo 0) {
            children[i].hitTestMapped(cx, cy)?.let { return it }
        }
        return MappedHit(this, px, py)
    }
}

// ---------------------------------------------------------------- paint

/** The paint sink: Widgets record ops; the Compose draw modifier maps them
 *  to real DrawScope calls on the Skiko surface. */
interface PaintSink {
    fun fillRect(x: Float, y: Float, w: Float, h: Float, color: Long)
    fun fillRRect(x: Float, y: Float, w: Float, h: Float, radius: Float, color: Long)
    fun text(text: String, x: Float, yBaseline: Float, size: Float, bold: Boolean, color: Long)
}

data class TextMetrics(val width: Float, val height: Float, val ascent: Float)

/** Text metrics: the real provider (Skia font) is installed by ComposeHost
 *  at startup; the fallback is a deterministic estimate used only if the
 *  provider was never installed (unit smoke paths). */
object TextMeasure {
    var provider: (String, Float, Boolean) -> TextMetrics = { text, size, bold ->
        val adv = size * (if (bold) 0.62f else 0.58f)
        TextMetrics(text.length * adv, size * 1.2f, size * 0.9f)
    }
    fun measure(text: String, size: Float, bold: Boolean) = provider(text, size, bold)
}

// ---------------------------------------------------------------- scroll state

class ScrollInfo(val offset: Float, val maxOffset: Float, val viewport: Float, val content: Float) {
    fun canScroll() = maxOffset > 0
    fun thumbFraction(): Float {
        if (content <= 0) return 1f
        return (viewport / content).coerceIn(0.05f, 1f)
    }
}

class ScrollState2 {
    var offset = 0f
    var content = 0f
    var viewport = 0f
    fun maxOffset() = max(0f, content - viewport)
    fun info() = ScrollInfo(offset, maxOffset(), viewport, content)
    fun setOffset(value: Float): Boolean {
        val clamped = value.coerceIn(0f, maxOffset())
        if (clamped == offset) return false
        offset = clamped
        return true
    }
    fun scrollBy(dy: Float) = setOffset(offset + dy)
}

class IRange(val first: Int, val last: Int)

fun visibleRange(itemCount: Int, stride: Float, viewport: Float, offset: Float, margin: Int): IRange {
    if (itemCount == 0 || viewport <= 0 || stride <= 0) return IRange(0, 0)
    val first = max(0f, floor(offset / stride) - margin)
    val last = min(itemCount.toFloat(), ceil((offset + viewport) / stride) + margin)
    return IRange(first.toInt(), max(first, last).toInt())
}

// ---------------------------------------------------------------- semantic tree

class SemanticNode2(val node: KNode) {
    var role = SemRole.NONE
    var label = ""
    var hint = ""
    var value = ""
    var checked: Boolean? = null
    var disabled = false
    var focusable = false
    var actions = Actions2()
    val children = mutableListOf<SemanticNode2>()
}

fun firstDescendantLabel(n: KNode): String? {
    for (c in n.children) {
        if (c.excludeSemantics || !c.visible) continue
        c.semantics?.let { if (it.label.isNotEmpty()) return it.label }
        firstDescendantLabel(c)?.let { return it }
    }
    return null
}

private fun flattenInto(n: KNode, list: MutableList<SemanticNode2>) {
    if (n.excludeSemantics || !n.visible) return
    n.semantics?.let { sem ->
        val sn = SemanticNode2(n)
        for (c in n.children) flattenInto(c, sn.children)
        sn.role = sem.role
        sn.label = if (sem.label.isNotEmpty()) sem.label else firstDescendantLabel(n) ?: ""
        sn.hint = sem.hint; sn.value = sem.value; sn.checked = sem.checked
        sn.disabled = sem.disabled; sn.focusable = sem.focusable
        sn.actions = sem.actions.copy()
        list.add(sn)
    } ?: run {
        for (c in n.children) flattenInto(c, list)
    }
}

/** The flattened tree assistive tech sees; a .group wrapper is synthesized
 *  when the root has no descriptor of its own (same rule as the reference). */
fun buildSemanticTree(root: KNode): SemanticNode2 {
    val list = ArrayList<SemanticNode2>()
    flattenInto(root, list)
    if (list.size == 1) return list[0]
    val g = SemanticNode2(root)
    g.role = SemRole.GROUP
    g.children.addAll(list)
    return g
}

// ---------------------------------------------------------------- focus manager

class FocusManager {
    var root: KNode? = null
    var focused: KNode? = null
        private set
    var onFocusChanged: ((KNode?) -> Unit)? = null

    fun focusOrder(): List<KNode> {
        val r = root ?: return emptyList()
        val tree = buildSemanticTree(r)
        val out = ArrayList<KNode>()
        fun collect(sn: SemanticNode2) {
            if (sn.focusable) out.add(sn.node)
            for (c in sn.children) collect(c)
        }
        collect(tree)
        return out
    }

    fun focusNode(node: KNode?) {
        setFocused(node)
        Engine.current?.let { it.router.focused = node }
    }

    /** The router's focus moved (pointer click, Escape blur) — sync without
     *  re-entering the router. */
    fun onRouterFocusChanged(node: KNode?) = setFocused(node)

    private fun setFocused(node: KNode?) {
        if (focused === node) return
        val r = root
        focused?.let { old ->
            old.markDirty()
            r?.let { damageRectOf(it, ringRect(old)) }
        }
        if (node != null) r?.let { damageRectOf(it, ringRect(node)) }
        focused = node
        node?.markDirty()
        onFocusChanged?.invoke(node)
    }

    private fun ringRect(n: KNode) = n.mapRectToRoot(n.bounds).let {
        Rect2(it.x - RING_OFFSET, it.y - RING_OFFSET, it.w + 2 * RING_OFFSET, it.h + 2 * RING_OFFSET)
    }
    private fun damageRectOf(root: KNode, rect: Rect2) { Engine.current?.unionDamage(rect) }

    fun focusNext() {
        val order = focusOrder()
        if (order.isEmpty()) return
        val idx = order.indexOf(focused).let { if (it < 0) order.size - 1 else it }
        focusNode(order[(idx + 1) % order.size])
    }
    fun focusPrev() {
        val order = focusOrder()
        if (order.isEmpty()) return
        val idx = order.indexOf(focused).let { if (it < 0) 0 else it }
        focusNode(order[(idx + order.size - 1) % order.size])
    }

    /** Tab/Shift+Tab cycle; Enter/Space activates a node advertising the
     *  activate action via a synthesized center tap through the router. */
    fun handleKey(ev: KeyEv): Boolean {
        if (ev.kind != KeyEv.Kind.KEY_DOWN) return false
        return when (ev.key) {
            KKey.TAB -> { if (ev.shift) focusPrev() else focusNext(); true }
            KKey.ENTER, KKey.SPACE -> {
                val n = focused ?: return false
                val sem = n.semantics ?: return false
                if (!sem.actions.contains("activate")) return false
                activateNode(n)
                true
            }
            else -> false
        }
    }

    private fun activateNode(node: KNode) {
        val r = root ?: return
        val router = Engine.current?.router ?: return
        val mapped = node.mapRectToRoot(node.bounds)
        val cx = mapped.x + mapped.w / 2; val cy = mapped.y + mapped.h / 2
        router.dispatchPointer(r, PointerEv(PointerPhase.DOWN, x = cx, y = cy))
        router.dispatchPointer(r, PointerEv(PointerPhase.UP, x = cx, y = cy))
    }

    companion object { const val RING_OFFSET = 3f }
}

// ---------------------------------------------------------------- input router

class InputRouter {
    val captures = arrayOfNulls<KNode>(MAX_POINTERS)
    val capturePointerIds = IntArray(MAX_POINTERS) { -1 }
    var hovered: KNode? = null
    var focused: KNode? = null
    var lastX = 0f; var lastY = 0f; var hasLast = false
    val backStack = ArrayList<() -> Boolean>()
    var backHandler: (() -> Boolean)? = null

    fun capturedNode(pointer: Int): KNode? {
        for (i in 0 until MAX_POINTERS) if (capturePointerIds[i] == pointer) return captures[i]
        return null
    }
    private fun captureSet(pointer: Int, node: KNode) {
        for (i in 0 until MAX_POINTERS) if (capturePointerIds[i] == pointer) { captures[i] = node; return }
        for (i in 0 until MAX_POINTERS) if (capturePointerIds[i] < 0) { capturePointerIds[i] = pointer; captures[i] = node; return }
    }
    private fun captureClear(pointer: Int) {
        for (i in 0 until MAX_POINTERS) if (capturePointerIds[i] == pointer) { capturePointerIds[i] = -1; captures[i] = null }
    }

    fun dispatchPointer(root: KNode, evIn: PointerEv) {
        val ev = PointerEv(evIn.phase, evIn.x, evIn.y, evIn.x, evIn.y, evIn.pointer, evIn.timeMs)
        if (ev.pointer == 0) { lastX = ev.x; lastY = ev.y; hasLast = true }
        when (ev.phase) {
            PointerPhase.DOWN -> {
                root.hitTestMapped(ev.x, ev.y)?.let { hit ->
                    captureSet(ev.pointer, hit.node)
                    sendPointer(hit.node, PointerEv(ev.phase, hit.x, hit.y, ev.rawX, ev.rawY, ev.pointer, ev.timeMs))
                }
            }
            PointerPhase.MOVE -> {
                val c = capturedNode(ev.pointer)
                if (c != null) {
                    val (lx, ly) = c.mapPointToParentSpace(ev.x, ev.y)
                    sendPointer(c, PointerEv(ev.phase, lx, ly, ev.rawX, ev.rawY, ev.pointer, ev.timeMs))
                } else if (ev.pointer == 0) {
                    updateHover(root, ev.x, ev.y, true)
                }
            }
            PointerPhase.UP -> {
                val c = capturedNode(ev.pointer)
                if (c != null) {
                    captureClear(ev.pointer)
                    val (lx, ly) = c.mapPointToParentSpace(ev.x, ev.y)
                    sendPointer(c, PointerEv(ev.phase, lx, ly, ev.rawX, ev.rawY, ev.pointer, ev.timeMs))
                    if (ev.pointer == 0) refreshHover(root)
                } else {
                    root.hitTestMapped(ev.x, ev.y)?.let { hit ->
                        sendPointer(hit.node, PointerEv(ev.phase, hit.x, hit.y, ev.rawX, ev.rawY, ev.pointer, ev.timeMs))
                    }
                }
            }
            else -> {}
        }
    }

    fun dispatchScroll(root: KNode, ev: ScrollEv) {
        if (ev.pointer == 0) { lastX = ev.x; lastY = ev.y; hasLast = true }
        val hit = root.hitTest(ev.x, ev.y) ?: return
        sendScroll(hit, ev)
    }

    fun dispatchKey(ev: KeyEv): Boolean {
        val f = focused ?: return false
        return sendKey(f, ev)
    }

    /** Escape/hardware back: the focused chain sees `.escape` first (a text
     *  field consumes it to blur), then modal back handlers, then the
     *  navigator's back handler. */
    fun dispatchBack(): Boolean {
        focused?.let { if (sendKey(it, KeyEv(KeyEv.Kind.KEY_DOWN, KKey.ESCAPE))) return true }
        if (backStack.isNotEmpty()) return backStack[backStack.size - 1]()
        backHandler?.let { return it() }
        return false
    }

    private fun updateHover(root: KNode, x: Float, y: Float, sendMove: Boolean) {
        val hit = root.hitTestMapped(x, y)
        val node = hit?.node
        if (node !== hovered) {
            hovered?.let { sendPointer(it, PointerEv(PointerPhase.LEAVE, x, y, x, y)) }
            hovered = node
            hit?.let { sendPointer(it.node, PointerEv(PointerPhase.ENTER, it.x, it.y, x, y)) }
        } else if (sendMove) {
            hit?.let { sendPointer(it.node, PointerEv(PointerPhase.HOVER_MOVE, it.x, it.y, x, y)) }
        }
    }

    fun refreshHover(root: KNode) { if (hasLast) updateHover(root, lastX, lastY, false) }

    private fun sendPointer(node: KNode, ev: PointerEv): Boolean {
        val notify = ev.phase == PointerPhase.ENTER || ev.phase == PointerPhase.LEAVE || ev.phase == PointerPhase.HOVER_MOVE
        var handled = false
        var n: KNode? = node
        while (n != null) {
            val h = n.pointerHandler
            if (h != null && h(n, ev)) {
                handled = true
                if (!notify) return true
            }
            n = n.parent
        }
        return handled
    }

    private fun sendKey(node: KNode, ev: KeyEv): Boolean {
        var n: KNode? = node
        while (n != null) {
            val h = n.keyHandler
            if (h != null && h(n, ev)) return true
            n = n.parent
        }
        return false
    }

    private fun sendScroll(node: KNode, ev: ScrollEv): Boolean {
        var n: KNode? = node
        while (n != null) {
            val h = n.scrollHandler
            if (h != null && h(n, ev)) return true
            n = n.parent
        }
        return false
    }

    /** Pointer-activated focus (TextField .down): router + focus manager +
     *  bridge. Mirrors input.requestFocus. */
    fun requestFocus(node: KNode?) {
        if (focused != null && focused !== node) focused!!.markDirty()
        focused = node
        Engine.current?.fm?.onRouterFocusChanged(node)
    }

    fun isFocused(node: KNode) = focused === node

    fun releaseNode(node: KNode) {
        for (i in 0 until MAX_POINTERS) if (captures[i] === node) { captures[i] = null; capturePointerIds[i] = -1 }
        if (hovered === node) hovered = null
        if (focused === node) focused = null
    }

    companion object { const val MAX_POINTERS = 8 }
}

// ---------------------------------------------------------------- timeline

/** Deterministic virtual clock: tickers (gesture arenas) are advanced by
 *  `tick` ops and by pointer-event timestamps. No wall-clock sleeps. */
class Timeline {
    private val tickers = ArrayList<(Long) -> Unit>()
    var nowMs = 0L
        private set

    fun addTicker(t: (Long) -> Unit) { tickers.add(t) }
    fun removeTicker(t: (Long) -> Unit) { tickers.remove(t) }

    fun tick(nowMs: Long) {
        this.nowMs = nowMs
        for (t in tickers.toList()) t(nowMs)
    }

    /** Advance to an event timestamp (gesture deadlines are event-driven
     *  too — a still-held pointer fires long-press on release). */
    fun advanceTo(ms: Long) { if (ms > nowMs) tick(ms) }
}
