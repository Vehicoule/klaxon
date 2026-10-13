// The conformance engine — Kotlin port of src/conformance.zig's Harness:
// deterministic globals (router / timeline / focus / a11y bridge / i18n /
// navigator / signals / effects / memo), the setup parsers, the action
// replay loop, and every expectation evaluator.
//
// Pixel expectations render through the real Compose scene (ComposeHost);
// everything else reads the ported model the scene is driven by.
package conf.compose

import kotlin.math.abs
import kotlin.math.max

const val DEFAULT_TOLERANCE = 0.01f

/** A logged a11y bridge event (reference LogBridge.LoggedEvent). */
class A11yEvent(val kind: String, val text: String = "")

/** The a11y log bridge — mirrors semantics.LogBridge: every bridge event is
 *  recorded in order; expectA11yEvents compares kind + text. */
class A11yBridge {
    val events = ArrayList<A11yEvent>()
    fun treeDirty() { events.add(A11yEvent("tree_dirty")) }
    fun focusChanged() { events.add(A11yEvent("focus_changed")) }
    fun announce(text: String, region: String) { events.add(A11yEvent("announce", text)) }
    fun controlChanged(n: KNode) { events.add(A11yEvent("control_changed")) }
}

class EffectDef(
    val e: Engine,
    val name: String,
    val reads: List<String>,
    val op: String, // "add" | "mul" | "first"
) {
    var effect: Effect? = null
    fun run() {
        var acc = if (op == "mul") 1L else 0L
        var first = true
        for (r in reads) {
            val v = e.readRef(r) ?: 0
            when (op) {
                "mul" -> acc *= v
                "first" -> if (first) acc = v
                else -> acc += v
            }
            first = false
        }
        e.effectLog.add("$name=$acc")
    }
}

/** Harness = the test-scoped context. `Engine.current` plays the role of
 *  the reference's process globals (setCurrent router/timeline/focus/
 *  bridge/i18n) — the runner is single-threaded and sets it for the
 *  duration of each test. */
class Engine {
    val ids = LinkedHashMap<String, KNode>()
    val scrollKind = HashMap<String, String>() // "view" | "list"
    val sigInt = HashMap<String, KSignal<Long>>()
    val sigBool = HashMap<String, KSignal<Boolean>>()
    val sigFloat = HashMap<String, KSignal<Float>>()
    val sigText = HashMap<String, TextSignal>()
    val effects = ArrayList<EffectDef>()
    var memo: Memo? = null
    var memoSrc: Triple<KSignal<Long>, KSignal<Long>, String>? = null

    val router = InputRouter()
    val timeline = Timeline()
    val fm = FocusManager()
    val a11y = A11yBridge()
    var i18n: I18n? = null
    var nav: Navigator? = null
    var root: KNode? = null
    var viewport = Rect2(0f, 0f, 800f, 600f)

    val gestureLog = ArrayList<String>()
    val events = ArrayList<String>()
    val effectLog = ArrayList<String>()
    var lastError: String? = null

    // The root's damage accumulator (root.damage / damage_valid upstream).
    var damage = Rect2()
    var damageValid = false
    fun unionDamage(r: Rect2) {
        if (r.w <= 0 || r.h <= 0) return
        damage = if (damageValid) damage.union(r) else r.copy()
        damageValid = true
    }
    fun clearDamage() { damage = Rect2(); damageValid = false }

    init {
        fm.onFocusChanged = { a11y.focusChanged() }
    }

    fun sigInt(name: String, initial: Long): KSignal<Long> =
        sigInt.getOrPut(name) { KSignal(initial) }
    fun sigBool(name: String, initial: Boolean): KSignal<Boolean> =
        sigBool.getOrPut(name) { KSignal(initial) }
    fun sigFloat(name: String, initial: Float): KSignal<Float> =
        sigFloat.getOrPut(name) { KSignal(initial) }

    /** "a" → tracked read; "peek:a" → untracked; "memo" → the test's memo. */
    fun readRef(ref: String): Long? {
        if (ref == "memo") return memo?.get()
        if (ref.startsWith("peek:")) return sigInt[ref.substring(5)]?.peek()
        return sigInt[ref]?.get()
    }

    fun findNode(id: String) = ids[id]

    /** True while `n` is still inside the live tree (virtualized list items
     *  die as they leave the window). */
    fun isLive(n: KNode): Boolean {
        val r = root ?: return false
        var cur: KNode? = n
        while (cur != null) {
            if (cur === r) return true
            cur = cur.parent
        }
        return false
    }

    fun idFor(n: KNode): String {
        for ((k, v) in ids) if (v === n) return k
        return "(unnamed)"
    }

    /** Raster a frame through the real Compose scene, then clear damage —
     *  the reference host clears the accumulator after every paint. */
    fun renderFrame(): Frame {
        val host = ComposeHost.forEngine(this)
        val frame = host.render()
        clearDamage()
        return frame
    }

    /** The semantics tree for `a11y`: read from the real Compose
     *  SemanticsOwner when the scene is up; the model flatten is the
     *  fallback when the reflective bridge fails (documented). */
    fun semanticTreeForChecks(): SemanticNode2? {
        val r = root ?: return null
        return try {
            ComposeHost.forEngine(this)
            ComposeHost.resetSemModelWalk()
            ComposeHost.render() // composition must lay out to expose semantics
            ComposeHost.semanticTree() ?: modelSemanticTree()
        } catch (t: Throwable) {
            modelSemanticTree()
        }
    }

    fun modelSemanticTree(): SemanticNode2? = root?.let { buildSemanticTree(it) }

    fun destroyTree() {
        root?.let { releaseIds(it, this) }
        root = null
    }

    companion object {
        var current: Engine? = null
    }
}

// ------------------------------------------------------------------ setup

fun setupSignals(e: Engine, sigs: JVal?) {
    val o = sigs?.obj ?: return
    for ((name, v) in o) {
        when (v) {
            is JVal.JBool -> e.sigBool(name, v.v)
            is JVal.JNum -> {
                if (v.v == Math.floor(v.v) && !v.v.isInfinite()) e.sigInt(name, v.v.toLong())
                else e.sigFloat(name, v.v.toFloat())
            }
            is JVal.JStr -> e.sigText[name] = TextSignal(v.v)
            is JVal.JObj -> {
                if (v.obj?.get("type").strOr("") == "text") {
                    e.sigText[name] = TextSignal(v.obj?.get("value").strOr(""))
                }
            }
            else -> {}
        }
    }
}

fun setupEffects(e: Engine, defs: JVal?) {
    val arr = defs?.arr ?: return
    for (dv in arr) {
        val reads = ArrayList<String>()
        dv.prop("reads")?.arr?.forEach { rv -> reads.add(rv.strOr("")) }
        val d = EffectDef(e, dv.prop("name").strOr("effect"), reads,
            when (dv.prop("op").strOr("add")) { "mul" -> "mul"; "first" -> "first"; else -> "add" })
        d.effect = Effect { d.run() }
        e.effects.add(d)
        d.effect!!.run() // first run: resolve + subscribe
    }
}

fun setupMemo(e: Engine, def: JVal?) {
    val o = def?.obj ?: return
    val args = o["args"]?.arr ?: return
    if (args.size < 2) return
    val a = e.sigInt[args[0].strOr("")] ?: return
    val b = e.sigInt[args[1].strOr("")] ?: return
    val op = when (o["op"].strOr("add")) { "sub" -> "sub"; "mul" -> "mul"; else -> "add" }
    e.memoSrc = Triple(a, b, op)
    e.memo = Memo {
        val (sa, sb, sop) = e.memoSrc!!
        when (sop) { "sub" -> sa.get() - sb.get(); "mul" -> sa.get() * sb.get(); else -> sa.get() + sb.get() }
    }
}

fun setupI18n(e: Engine, v: JVal?) {
    val o = v?.obj ?: return
    val i18n = I18n(o["fallback"].strOr("en"))
    e.i18n = i18n
    o["locales"]?.obj?.let { locs ->
        for ((tag, lv) in locs) {
            val dir = o["dirs"]?.obj?.get(tag)?.strOr("ltr") == "rtl"
            val arb = when (lv) {
                is JVal.JStr -> lv.v
                is JVal.JObj -> { val sb = StringBuilder(); lv.toJson(sb); sb.toString() }
                else -> continue
            }
            i18n.addArb(tag, arb, if (dir) Direction.RTL else Direction.LTR)
        }
    }
    o["locale"]?.str?.let { i18n.setLocale(it) }
    i18n.onDirectionChanged = { /* tree re-layout happens on next layout pass */ }
}

fun setupNavigator(e: Engine, v: JVal?) {
    val o = v?.obj ?: return
    val nv = Navigator()
    e.nav = nv
    nv.onChange = { kind -> e.events.add("nav:${kind.name}") }
    // Page content is a fixed box — nav semantics don't depend on it
    // (mirrors navPageCb: a 10×10 #333333FF box with id "page").
    val pageBuilder: (Route) -> KNode = { makeBox(e, "page", 10f, 10f, 0x333333FF, false) }
    o["routes"]?.arr?.forEach { rv ->
        val pattern = rv.prop("pattern").strOr("")
        if (pattern.isEmpty()) return@forEach
        nv.define(pattern, pageBuilder, parseTransition(rv.prop("transition").strOr("slide")))
    }
}

// ------------------------------------------------------------------ actions

fun paramsFromJson(v: JVal?): List<Pair<String, String>> {
    val list = ArrayList<Pair<String, String>>()
    v?.obj?.forEach { (k, p) -> list.add(k to p.strOr("")) }
    return list
}

/** One action. Errors land in `lastError` (the `action_error` expect key
 *  checks them) instead of failing the test. */
fun runAction(e: Engine, av: JVal) {
    val op = av.prop("op").strOr("")
    try {
        runActionInner(e, op, av)
    } catch (err: ConfError) {
        e.lastError = err.code
    } catch (err: Exception) {
        e.lastError = err::class.simpleName ?: "Error"
    }
}

fun runActionInner(e: Engine, op: String, av: JVal) {
    when (op) {
        "pointer" -> {
            val root = e.root ?: throw ConfError("NoTree")
            val phase = when (av.prop("phase").strOr("move")) {
                "down" -> PointerPhase.DOWN; "up" -> PointerPhase.UP; else -> PointerPhase.MOVE
            }
            e.router.dispatchPointer(root, PointerEv(phase,
                x = av.prop("x").numOf(0f), y = av.prop("y").numOf(0f),
                pointer = max(0, av.prop("pointer").intOf(0)).toInt(),
                timeMs = max(0, av.prop("t").intOf(0))))
        }
        "scroll" -> {
            val root = e.root ?: throw ConfError("NoTree")
            e.router.dispatchScroll(root, ScrollEv(
                x = av.prop("x").numOf(0f), y = av.prop("y").numOf(0f),
                deltaX = av.prop("dx").numOf(0f), deltaY = av.prop("dy").numOf(0f),
                timeMs = max(0, av.prop("t").intOf(0))))
            e.router.refreshHover(root) // content moves under the pointer
        }
        "key" -> {
            val (key, char) = parseKeyName(av.prop("key").strOr("unknown"))
            val ev = KeyEv(KeyEv.Kind.KEY_DOWN, key,
                shift = av.prop("shift").boolOr(false), char = char)
            // Host dispatch order: Escape/Back → back stack; Tab → focus
            // manager; anything else → focused chain, then FM activation.
            if (key == KKey.ESCAPE || key == KKey.BACK) {
                e.router.dispatchBack()
            } else if (key == KKey.TAB) {
                e.fm.handleKey(ev)
            } else {
                if (!e.router.dispatchKey(ev)) e.fm.handleKey(ev)
            }
        }
        "text_input" -> {
            e.router.dispatchKey(KeyEv(KeyEv.Kind.TEXT_INPUT, text = av.prop("text").strOr("")))
        }
        "tick" -> e.timeline.tick(max(0, av.prop("ms").intOf(0)))
        "focus" -> {
            val id = av.prop("id")?.str
            if (id != null) {
                e.fm.focusNode(e.findNode(id) ?: throw ConfError("UnknownNode"))
            } else e.fm.focusNode(null)
        }
        "mark_dirty" -> {
            val n = e.findNode(av.prop("id").strOr("")) ?: throw ConfError("UnknownNode")
            n.markDirty()
        }
        "mark_dirty_rect" -> {
            val n = e.findNode(av.prop("id").strOr("")) ?: throw ConfError("UnknownNode")
            n.markDirtyRect(parseRectV(av.prop("rect")) ?: throw ConfError("BadRect"))
        }
        "relayout" -> {
            e.viewport.w = av.prop("w").numOf(e.viewport.w)
            e.viewport.h = av.prop("h").numOf(e.viewport.h)
            val root = e.root ?: throw ConfError("NoTree")
            root.layout(Rect2(0f, 0f, e.viewport.w, e.viewport.h))
            ComposeHost.resize(e.viewport.w.toInt(), e.viewport.h.toInt())
        }
        "paint" -> { e.renderFrame() }
        "set_scroll" -> {
            val id = av.prop("id").strOr("")
            val n = e.findNode(id) ?: throw ConfError("UnknownNode")
            val off = av.prop("offset").numOf(0f)
            when (e.scrollKind[id] ?: "view") {
                "list" -> setListScrollOffset(n, off)
                else -> setScrollOffset(n, off)
            }
        }
        "list_count" -> {
            val n = e.findNode(av.prop("id").strOr("")) ?: throw ConfError("UnknownNode")
            setListItemCount(n, max(0, av.prop("count").intOf(0)).toInt())
        }
        "list_reload" -> {
            val n = e.findNode(av.prop("id").strOr("")) ?: throw ConfError("UnknownNode")
            reloadListItems(n)
        }
        "set_locale" -> {
            val i18n = e.i18n ?: throw ConfError("MissingI18n")
            i18n.setLocale(av.prop("tag").strOr(""))
        }
        "signal_set" -> {
            val name = av.prop("name").strOr("")
            val v = av.prop("value") ?: JVal.JNum(0.0)
            e.sigInt[name]?.let { it.set(v.numOr(0f).toLong()); return }
            e.sigBool[name]?.let { it.set(v.boolOr(false)); return }
            e.sigFloat[name]?.let { it.set(v.numOr(0f)); return }
            e.sigText[name]?.let {
                av.prop("len")?.let { lv ->
                    val len = max(0, lv.intOf(0)).toInt()
                    it.set("x".repeat(len))
                } ?: it.set(v.strOr(""))
                return
            }
            throw ConfError("UnknownSignal")
        }
        "signal_notify" -> {
            val name = av.prop("name").strOr("")
            e.sigInt[name]?.let { it.emit(); return }
            e.sigText[name]?.let { it.emit(); return }
            throw ConfError("UnknownSignal")
        }
        "nav_push" -> {
            val nv = e.nav ?: throw ConfError("MissingNavigator")
            nv.push(av.prop("pattern").strOr(""), paramsFromJson(av.prop("params")))
        }
        "nav_push_path" -> {
            val nv = e.nav ?: throw ConfError("MissingNavigator")
            nv.pushPath(av.prop("path").strOr(""), paramsFromJson(av.prop("params")))
        }
        "navigate" -> {
            val nv = e.nav ?: throw ConfError("MissingNavigator")
            nv.navigateTo(av.prop("uri").strOr(""))
        }
        "nav_replace" -> {
            val nv = e.nav ?: throw ConfError("MissingNavigator")
            nv.replace(av.prop("pattern").strOr(""), paramsFromJson(av.prop("params")))
        }
        "nav_pop" -> {
            val nv = e.nav ?: throw ConfError("MissingNavigator")
            nv.pop()
        }
        "nav_back" -> {
            val nv = e.nav ?: throw ConfError("MissingNavigator")
            nv.onBack()
        }
        "nav_pop_to_root" -> {
            val nv = e.nav ?: throw ConfError("MissingNavigator")
            nv.popToRoot()
        }
        "announce" -> {
            e.a11y.announce(av.prop("text").strOr(""),
                if (av.prop("region").strOr("polite") == "assertive") "assertive" else "polite")
        }
        else -> throw ConfError("UnknownOp")
    }
}

// ------------------------------------------------------------------ expects

class Check(val failures: MutableList<String>, val tol: Float = DEFAULT_TOLERANCE) {
    fun fail(msg: String) { failures.add(msg) }
}

private fun nearEq(a: Float, b: Float, tol: Float) = abs(a - b) <= tol
private fun rectEq(a: Rect2, b: Rect2, tol: Float) =
    nearEq(a.x, b.x, tol) && nearEq(a.y, b.y, tol) && nearEq(a.w, b.w, tol) && nearEq(a.h, b.h, tol)

private fun liveNode(e: Engine, c: Check, id: String): KNode? {
    val n = e.findNode(id) ?: run { c.fail("unknown node id \"$id\""); return null }
    if (!e.isLive(n)) { c.fail("node \"$id\" is no longer in the tree"); return null }
    return n
}

fun checkExpect(e: Engine, c: Check, key: String, v: JVal) {
    when (key) {
        "rects" -> {
            v.obj?.forEach { (id, rv) ->
                val n = liveNode(e, c, id) ?: return@forEach
                val want = parseRectV(rv) ?: run { c.fail("rects.$id: expected [x,y,w,h]"); return@forEach }
                if (!rectEq(n.bounds, want, c.tol))
                    c.fail("rects.$id: expected [${want.x},${want.y},${want.w},${want.h}] got [${n.bounds.x},${n.bounds.y},${n.bounds.w},${n.bounds.h}]")
            }
        }
        "measured" -> {
            v.obj?.forEach { (id, rv) ->
                val n = liveNode(e, c, id) ?: return@forEach
                val want = parseAlignmentV(rv) ?: run { c.fail("measured.$id: expected [w,h]"); return@forEach }
                val got = n.measure(Constraints2(0f, e.viewport.w, 0f, e.viewport.h))
                if (!nearEq(got.w, want.x, c.tol) || !nearEq(got.h, want.y, c.tol))
                    c.fail("measured.$id: expected [${want.x},${want.y}] got [${got.w},${got.h}]")
            }
        }
        "damage" -> {
            if (v.isNull) {
                if (e.damageValid) c.fail("damage: expected none, got [${e.damage.x},${e.damage.y},${e.damage.w},${e.damage.h}]")
            } else {
                val want = parseRectV(v) ?: run { c.fail("damage: expected [x,y,w,h] or null"); return }
                if (!e.damageValid) c.fail("damage: expected [${want.x},${want.y},${want.w},${want.h}] got none")
                else if (!rectEq(e.damage, want, c.tol))
                    c.fail("damage: expected [${want.x},${want.y},${want.w},${want.h}] got [${e.damage.x},${e.damage.y},${e.damage.w},${e.damage.h}]")
            }
        }
        "focused" -> expectFocused(e, c, v, false)
        "router_focused" -> expectFocused(e, c, v, true)
        "focus_order" -> {
            v.arr?.let { arr ->
                val got = e.fm.focusOrder().map { e.idFor(it) }
                expectSeq(c, "focus_order", arr.map { it.strOr("?") }, got)
            }
        }
        "gestures" -> v.arr?.let { expectSeq(c, "gestures", it.map { a -> a.strOr("?") }, e.gestureLog) }
        "events" -> v.arr?.let { expectSeq(c, "events", it.map { a -> a.strOr("?") }, e.events) }
        "effect_log" -> v.arr?.let { expectSeq(c, "effect_log", it.map { a -> a.strOr("?") }, e.effectLog) }
        "signals" -> {
            v.obj?.forEach { (name, fv) ->
                e.sigInt[name]?.let { s ->
                    val want = fv.numOr(0f).toLong()
                    if (s.peek() != want) c.fail("signals.$name: expected $want, got ${s.peek()}")
                    return@forEach
                }
                e.sigBool[name]?.let { s ->
                    val want = fv.boolOr(false)
                    if (s.peek() != want) c.fail("signals.$name: expected $want, got ${s.peek()}")
                    return@forEach
                }
                e.sigFloat[name]?.let { s ->
                    val want = fv.numOr(0f)
                    if (!nearEq(s.peek(), want, c.tol)) c.fail("signals.$name: expected $want, got ${s.peek()}")
                    return@forEach
                }
                e.sigText[name]?.let { s ->
                    val want = fv.strOr("")
                    if (s.peek() != want) c.fail("signals.$name: expected \"$want\", got \"${s.peek()}\"")
                    return@forEach
                }
                c.fail("signals.$name: unknown signal")
            }
        }
        "memo_value" -> {
            val m = e.memo ?: run { c.fail("memo_value: no memo in setup"); return }
            val want = v.numOr(0f).toLong()
            if (m.get() != want) c.fail("memo_value: expected $want, got ${m.get()}")
        }
        "a11y" -> flattenSem(e, c, v)
        "a11y_events" -> {
            v.arr?.let { arr ->
                for ((i, ev) in arr.withIndex()) {
                    if (i >= e.a11y.events.size) {
                        c.fail("a11y_events[$i]: expected \"${ev.prop("kind").strOr("?")}\", log ended at ${e.a11y.events.size} events")
                        return
                    }
                    val got = e.a11y.events[i]
                    ev.prop("kind")?.str?.let { k ->
                        if (got.kind != k) {
                            c.fail("a11y_events[$i]: expected kind \"$k\", got \"${got.kind}\"")
                            return
                        }
                    }
                    ev.prop("text")?.str?.let { t ->
                        if (got.text != t) {
                            c.fail("a11y_events[$i]: expected text \"$t\", got \"${got.text}\"")
                            return
                        }
                    }
                }
                if (e.a11y.events.size != arr.size)
                    c.fail("a11y_events: expected ${arr.size} events, got ${e.a11y.events.size}")
            }
        }
        "text" -> {
            v.obj?.forEach { (id, fv) ->
                val n = liveNode(e, c, id) ?: return@forEach
                val s = n.semantics ?: run { c.fail("text.$id: node has no semantics"); return@forEach }
                val got = if (s.label.isNotEmpty()) s.label else s.value
                val want = fv.strOr("")
                if (got != want) c.fail("text.$id: expected \"$want\", got \"$got\"")
            }
        }
        "i18n" -> expectI18n(e, c, v)
        "pixels" -> {
            v.arr?.let { arr ->
                var frame: Frame? = null
                try { frame = e.renderFrame() } catch (t: Throwable) {
                    c.fail("pixels: render failed: ${t.message}")
                    return
                }
                for ((i, pv) in arr.withIndex()) {
                    val want = parseColorV(pv.prop("color"))
                    if (want == null) { c.fail("pixels[$i]: missing color") } else {
                        val got = frame.pixelAt(pv.prop("x").numOf(0f).toInt(), pv.prop("y").numOf(0f).toInt())
                        val approx = pv.prop("approx").boolOr(false)
                        val ok = if (approx)
                            channelDiff(got, want, 24) <= 2 && channelDiff(got, want, 16) <= 2 &&
                                channelDiff(got, want, 8) <= 2 && channelDiff(got, want, 0) <= 2
                        else got == want
                        if (!ok) c.fail("pixels[$i] at (${pv.prop("x").numOf(0f)},${pv.prop("y").numOf(0f)}): expected #%08x, got #%08x"
                            .format(want, got))
                    }
                }
            }
        }
        "pixel_counts" -> {
            v.arr?.let { arr ->
                var frame: Frame? = null
                try { frame = e.renderFrame() } catch (t: Throwable) {
                    c.fail("pixel_counts: render failed: ${t.message}")
                    return
                }
                for ((i, pv) in arr.withIndex()) {
                    val color = parseColorV(pv.prop("color"))
                    if (color == null) { c.fail("pixel_counts[$i]: missing color") } else {
                        val rect = parseRectV(pv.prop("rect"))
                        val n = if (rect != null) frame.countColorIn(rect, color) else frame.countColor(color)
                        pv.prop("exact")?.let { ev ->
                            val want = max(0, ev.intOf(0))
                            if (n.toLong() != want) c.fail("pixel_counts[$i]: expected exactly $want of #%08x, got $n".format(color))
                        }
                        pv.prop("min")?.let { ev ->
                            val want = max(0, ev.intOf(0))
                            if (n.toLong() < want) c.fail("pixel_counts[$i]: expected ≥$want of #%08x, got $n".format(color))
                        }
                        pv.prop("max")?.let { ev ->
                            val want = max(0, ev.intOf(0))
                            if (n.toLong() > want) c.fail("pixel_counts[$i]: expected ≤$want of #%08x, got $n".format(color))
                        }
                    }
                }
            }
        }
        "scroll" -> {
            v.obj?.forEach { (id, fv) ->
                val n = liveNode(e, c, id) ?: return@forEach
                val got = scrollOffsetOf(n)
                val want = fv.numOr(0f)
                if (!nearEq(got, want, c.tol)) c.fail("scroll.$id: expected $want, got $got")
            }
        }
        "scroll_info" -> {
            v.obj?.forEach { (id, fv) ->
                val n = liveNode(e, c, id) ?: return@forEach
                val info = scrollInfoOf(n) ?: run { c.fail("scroll_info.$id: node is not scrollable"); return@forEach }
                fv.obj?.let { o ->
                    for (field in listOf("offset", "max_offset", "viewport", "content", "thumb")) {
                        o[field]?.let { ev ->
                            val got = if (field == "thumb") info.thumbFraction() else when (field) {
                                "offset" -> info.offset; "max_offset" -> info.maxOffset
                                "viewport" -> info.viewport; else -> info.content
                            }
                            val want = ev.numOr(0f)
                            if (!nearEq(got, want, c.tol)) c.fail("scroll_info.$id.$field: expected $want, got $got")
                        }
                    }
                }
            }
        }
        "children" -> {
            v.obj?.forEach { (id, fv) ->
                val n = liveNode(e, c, id) ?: return@forEach
                val want = max(0, fv.intOf(0)).toInt()
                if (n.children.size != want) c.fail("children.$id: expected $want, got ${n.children.size}")
            }
        }
        "first_item" -> {
            v.obj?.forEach { (id, fv) ->
                val n = liveNode(e, c, id) ?: return@forEach
                if (n.children.isEmpty()) { c.fail("first_item.$id: no live items"); return@forEach }
                val s = n.children[0].state as? BoxState
                val want = max(0, fv.intOf(0)).toInt()
                if (s?.itemIndex != want) c.fail("first_item.$id: expected $want, got ${s?.itemIndex}")
            }
        }
        "nav" -> {
            val nv = e.nav ?: run { c.fail("nav expects require setup.navigator"); return }
            v.obj?.let { o ->
                o["depth"]?.let { dv ->
                    val want = max(0, dv.intOf(0)).toInt()
                    if (nv.depth() != want) c.fail("nav.depth: expected $want, got ${nv.depth()}")
                }
                o["current"]?.str?.let { want ->
                    val got = nv.current()?.route?.path ?: ""
                    if (got != want) c.fail("nav.current: expected \"$want\", got \"$got\"")
                }
                o["params"]?.obj?.let { pv ->
                    val cur = nv.current() ?: run { c.fail("nav.params: stack empty"); return }
                    for ((k, p) in pv) {
                        val got = cur.route.params.get(k) ?: ""
                        if (got != p.strOr("")) c.fail("nav.params.$k: expected \"${p.strOr("")}\", got \"$got\"")
                    }
                }
            }
        }
        "action_error" -> {
            val want = v.strOr("")
            val got = e.lastError ?: ""
            if (got != want) c.fail("action_error: expected \"$want\", got \"$got\"")
        }
        else -> c.fail("unknown expect key \"$key\"")
    }
}

private fun expectFocused(e: Engine, c: Check, v: JVal, routerSide: Boolean) {
    val n = if (routerSide) e.router.focused else e.fm.focused
    val key = if (routerSide) "router_focused" else "focused"
    if (v.isNull) {
        if (n != null) c.fail("$key: expected null, got \"${e.idFor(n)}\"")
        return
    }
    val want = v.strOr("")
    val got = if (n != null) e.idFor(n) else ""
    if (n == null || got != want)
        c.fail("$key: expected \"$want\", got ${if (n == null) "null" else got}")
}

private fun expectSeq(c: Check, key: String, want: List<String>, got: List<String>) {
    val n = max(want.size, got.size)
    for (i in 0 until n) {
        val w = if (i < want.size) want[i] else "<missing>"
        val g = if (i < got.size) got[i] else "<missing>"
        if (w != g) {
            c.fail("$key[$i]: expected \"$w\", got \"$g\" (full got: $got)")
            return
        }
    }
}

/** Flattened semantic tree: pre-order, dropping the synthetic group wrapper
 *  the builder adds when the root has no semantics of its own. */
private fun flattenSem(e: Engine, c: Check, v: JVal) {
    val root = e.root ?: return
    val tree = e.semanticTreeForChecks() ?: return
    val list = ArrayList<SemanticNode2>()
    val synthetic = tree.role == SemRole.GROUP && tree.label.isEmpty() && root.semantics == null
    fun flatten(n: SemanticNode2) {
        list.add(n)
        for (ch in n.children) flatten(ch)
    }
    if (synthetic) for (ch in tree.children) flatten(ch) else flatten(tree)
    val arr = v.arr ?: return
    if (arr.size != list.size) {
        c.fail("a11y: expected ${arr.size} semantic nodes, got ${list.size}")
        return
    }
    for ((ev, got) in arr.zip(list)) checkSemNode(c, ev, got)
}

private fun checkSemNode(c: Check, ev: JVal, got: SemanticNode2) {
    ev.prop("role")?.str?.let { r ->
        val want = parseRole(r)
        if (got.role != want) c.fail("a11y role: expected \"$r\", got \"${roleName(got.role)}\"")
    }
    ev.prop("label")?.str?.let { l ->
        if (got.label != l) c.fail("a11y label: expected \"$l\", got \"${got.label}\"")
    }
    ev.prop("hint")?.str?.let { t ->
        if (got.hint != t) c.fail("a11y hint: expected \"$t\", got \"${got.hint}\"")
    }
    ev.prop("value")?.str?.let { t ->
        if (got.value != t) c.fail("a11y value: expected \"$t\", got \"${got.value}\"")
    }
    ev.prop("checked")?.let { cv ->
        val want = cv.boolOr(false)
        if ((got.checked ?: false) != want) c.fail("a11y checked: expected $want, got ${got.checked ?: false}")
    }
    ev.prop("focusable")?.let { fv ->
        if (got.focusable != fv.boolOr(false)) c.fail("a11y focusable: expected ${fv.boolOr(false)}, got ${got.focusable}")
    }
    ev.prop("disabled")?.let { dv ->
        if (got.disabled != dv.boolOr(false)) c.fail("a11y disabled: expected ${dv.boolOr(false)}, got ${got.disabled}")
    }
}

private fun expectI18n(e: Engine, c: Check, v: JVal) {
    val i18n = e.i18n ?: run { c.fail("i18n expects require setup.i18n"); return }
    v.obj?.forEach { (fname, fv) ->
        val want = fv.strOr("")
        var got = ""
        when {
            fname == "direction" -> got = if (i18n.direction() == Direction.RTL) "rtl" else "ltr"
            fname.startsWith("tr:") -> got = i18n.tr(fname.substring(3))
            fname.startsWith("plural:") -> {
                val rest = fname.substring(7)
                val ci = rest.lastIndexOf(':')
                if (ci >= 0) {
                    val n = rest.substring(ci + 1).toLongOrNull() ?: 0
                    got = i18n.trPlural(rest.substring(0, ci), n, emptyMap())
                }
            }
            fname.startsWith("num:") -> {
                val rest = fname.substring(4)
                val opts = NumberOptions()
                var valstr = rest
                val ci = rest.indexOf(':')
                if (ci >= 0) {
                    valstr = rest.substring(0, ci)
                    for (tok in rest.substring(ci + 1).split(',')) {
                        when {
                            tok == "pct" -> opts.percent = true
                            tok == "nogroup" -> opts.grouping = false
                            tok.startsWith("dec=") -> opts.decimals = tok.substring(4).toIntOrNull()
                        }
                    }
                }
                val loc = i18n.locale() ?: return@forEach
                got = loc.formatNumber(valstr.toDoubleOrNull() ?: 0.0, opts)
            }
            fname.startsWith("date:") -> {
                val rest = fname.substring(5)
                val ci = rest.lastIndexOf(':')
                if (ci >= 0) {
                    val kind = when (rest.substring(ci + 1)) {
                        "long" -> DateKind.long; "medium" -> DateKind.medium; else -> DateKind.short
                    }
                    val parts = rest.substring(0, ci).split('-')
                    val y = parts.getOrNull(0)?.toIntOrNull() ?: 0
                    val m = parts.getOrNull(1)?.toIntOrNull() ?: 0
                    val d = parts.getOrNull(2)?.toIntOrNull() ?: 0
                    val loc = i18n.locale() ?: return@forEach
                    got = loc.formatDate(Date(y, m, d), kind)
                }
            }
        }
        if (got != want) c.fail("i18n.$fname: expected \"$want\", got \"$got\"")
    }
}

// ------------------------------------------------------------------ run

class TestResult(
    val id: String,
    val domain: String,
    val rule: String,
    var passed: Boolean = false,
    val failures: MutableList<String> = mutableListOf(),
)

/** Run one test vector end-to-end: setup → build → initial layout → clear
 *  frame-0 damage → replay actions → evaluate every expectation. */
fun runTest(tv: JVal): TestResult {
    val res = TestResult(
        id = tv.prop("id").strOr("?"),
        domain = tv.prop("domain").strOr("?"),
        rule = tv.prop("rule").strOr(""))
    val failures = res.failures
    val c = Check(failures, tv.prop("tolerance").numOf(DEFAULT_TOLERANCE))
    try {
        runTestInner(tv, c)
    } catch (err: ConfError) {
        c.fail("error: ${err.code}")
    } catch (err: Exception) {
        c.fail("error: ${err::class.simpleName}: ${err.message}")
    } finally {
        Engine.current = null
    }
    res.passed = failures.isEmpty()
    return res
}

private fun runTestInner(tv: JVal, c: Check) {
    val e = Engine()
    Engine.current = e
    try {
        val setup = tv.prop("setup") ?: JVal.EMPTY_OBJ
        setup.prop("viewport")?.arr?.let { vp ->
            if (vp.size >= 2) { e.viewport.w = vp[0].numOf(e.viewport.w); e.viewport.h = vp[1].numOf(e.viewport.h) }
        }
        setupSignals(e, setup.prop("signals"))
        setupI18n(e, setup.prop("i18n"))
        setupNavigator(e, setup.prop("navigator"))
        setupEffects(e, setup.prop("effects"))
        setupMemo(e, setup.prop("memo"))

        setup.prop("tree")?.let { tree ->
            e.root = buildNode(e, tree)
            e.fm.root = e.root
            e.root!!.layout(Rect2(0f, 0f, e.viewport.w, e.viewport.h))
            e.clearDamage() // frame-0 boundary: clean damage accumulator
            ComposeHost.mount(e)
        }

        tv.prop("actions")?.arr?.forEach { runAction(e, it) }

        val expect = tv.prop("expect") ?: return
        expect.obj?.forEach { (k, v) -> checkExpect(e, c, k, v) }
    } finally {
        e.destroyTree()
        Engine.current = null
    }
}
