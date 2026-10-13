// Gesture arena + recognizers — Kotlin port of src/ui/gestures.zig.
// Same tuned constants, same state machines, same arbitration:
//   - two-pointer recognizers (pinch/rotate) feed first and co-fire
//   - an accepted two-finger gesture claims the interaction
//   - pan start/update fire immediately; terminal gestures resolve after
//     the pass (double-tap suppresses the same-event tap)
package conf.compose

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.sqrt

object GestureTuning {
    const val SLOP = 12f
    const val TAP_TIMEOUT_MS = 200L
    const val DOUBLE_TAP_MS = 300L
    const val LONG_PRESS_MS = 500L
    const val SWIPE_VELOCITY = 500f
    const val VELOCITY_WINDOW_MS = 100L
}

enum class GKind { TAP, DOUBLE_TAP, LONG_PRESS, PAN, SWIPE, PINCH, ROTATE }

enum class SwipeDir { LEFT, RIGHT, UP, DOWN }

sealed class Fire {
    object Tap : Fire()
    object DoubleTap : Fire()
    object LongPress : Fire()
    data class PanStart(val dx: Float, val dy: Float) : Fire()
    data class PanUpdate(val dx: Float, val dy: Float) : Fire()
    data class PanEnd(val vx: Float, val vy: Float, val dx: Float, val dy: Float) : Fire()
    data class Swipe(val dir: SwipeDir, val vx: Float, val vy: Float) : Fire()
    data class Pinch(val scale: Float) : Fire()
    data class Rotate(val delta: Float) : Fire()
}

private fun dist(x1: Float, y1: Float, x2: Float, y2: Float): Float {
    val dx = x2 - x1; val dy = y2 - y1
    return sqrt(dx * dx + dy * dy)
}

class Recognizer(val kind: GKind) {
    enum class State { IDLE, POSSIBLE, ACCEPTED, REJECTED }
    var state = State.IDLE
    var tracking: Int? = null
    var startX = 0f; var startY = 0f; var startTime = 0L
    var lastX = 0f; var lastY = 0f
    val samples = Array(8) { Triple(0f, 0f, 0L) }
    var sampleLen = 0
    var hasLastTap = false
    var lastTapTime = 0L; var lastTapX = 0f; var lastTapY = 0f
    class TP(var id: Int, var x: Float, var y: Float)
    var ptrA: TP? = null; var ptrB: TP? = null
    var initialDistance = 0f; var initialAngle = 0f; var lastAngle = 0f
    var longPressFired = false

    fun reset() {
        state = State.IDLE
        tracking = null
        ptrA = null; ptrB = null
        longPressFired = false
        sampleLen = 0
    }

    fun feed(ev: PointerEv): Fire? = when (kind) {
        GKind.TAP -> feedTap(ev)
        GKind.DOUBLE_TAP -> feedDoubleTap(ev)
        GKind.LONG_PRESS -> feedLongPress(ev)
        GKind.PAN, GKind.SWIPE -> feedPan(ev)
        GKind.PINCH -> feedPinch(ev)
        GKind.ROTATE -> feedRotate(ev)
    }

    fun tick(nowMs: Long): Fire? {
        if (kind != GKind.LONG_PRESS) return null
        if (state != State.POSSIBLE || longPressFired) return null
        if (nowMs - startTime < GestureTuning.LONG_PRESS_MS) return null
        longPressFired = true
        state = State.IDLE
        tracking = null
        return Fire.LongPress
    }

    private fun follows(ev: PointerEv): Boolean {
        tracking?.let { return ev.pointer == it }
        return ev.phase == PointerPhase.DOWN
    }

    private fun beginDown(ev: PointerEv) {
        state = State.POSSIBLE
        tracking = ev.pointer
        startX = ev.x; startY = ev.y; startTime = ev.timeMs
        lastX = ev.x; lastY = ev.y
    }

    private fun addSample(ev: PointerEv) {
        if (sampleLen == samples.size) {
            for (i in 0 until samples.size - 1) samples[i] = samples[i + 1]
            samples[samples.size - 1] = Triple(ev.x, ev.y, ev.timeMs)
        } else {
            samples[sampleLen] = Triple(ev.x, ev.y, ev.timeMs)
            sampleLen += 1
        }
    }

    private fun trackDown(ev: PointerEv) {
        val a = ptrA
        if (a == null) {
            ptrA = TP(ev.pointer, ev.x, ev.y)
        } else if (ptrB == null && ev.pointer != a.id) {
            ptrB = TP(ev.pointer, ev.x, ev.y)
        }
        val pa = ptrA; val pb = ptrB
        if (pa != null && pb != null) {
            initialDistance = dist(pa.x, pa.y, pb.x, pb.y)
            initialAngle = atan2(pb.y - pa.y, pb.x - pa.x)
            lastAngle = initialAngle
            state = State.ACCEPTED
        }
    }

    private fun trackUp(ev: PointerEv): Boolean {
        var lifted = false
        ptrA?.let { if (it.id == ev.pointer) { ptrA = null; lifted = true } }
        ptrB?.let { if (it.id == ev.pointer) { ptrB = null; lifted = true } }
        if (lifted) state = State.IDLE
        return lifted
    }

    private fun trackMove(ev: PointerEv): Boolean {
        ptrA?.let { if (it.id == ev.pointer) { it.x = ev.x; it.y = ev.y; return true } }
        ptrB?.let { if (it.id == ev.pointer) { it.x = ev.x; it.y = ev.y; return true } }
        return false
    }

    private fun wrapAngle(d: Float): Float {
        var r = d
        val twoPi = (2 * Math.PI).toFloat()
        while (r > Math.PI) r -= twoPi
        while (r < -Math.PI) r += twoPi
        return r
    }

    private fun velocity(now: Long): Pair<Float, Float> {
        if (sampleLen == 0) return 0f to 0f
        var first = samples[sampleLen - 1]
        for (i in 0 until sampleLen) {
            if (now - samples[i].third <= GestureTuning.VELOCITY_WINDOW_MS) { first = samples[i]; break }
        }
        val last = samples[sampleLen - 1]
        val dtMs = last.third - first.third
        if (dtMs == 0L) return 0f to 0f
        val dt = dtMs / 1000f
        return ((last.first - first.first) / dt) to ((last.second - first.second) / dt)
    }

    private fun feedTap(ev: PointerEv): Fire? {
        if (!follows(ev)) return null
        return when (ev.phase) {
            PointerPhase.DOWN -> { beginDown(ev); null }
            PointerPhase.MOVE -> {
                if (state == State.POSSIBLE && dist(ev.x, ev.y, startX, startY) > GestureTuning.SLOP)
                    state = State.REJECTED
                lastX = ev.x; lastY = ev.y
                null
            }
            PointerPhase.UP -> {
                val ok = state == State.POSSIBLE &&
                    dist(ev.x, ev.y, startX, startY) <= GestureTuning.SLOP &&
                    ev.timeMs - startTime < GestureTuning.TAP_TIMEOUT_MS
                state = State.IDLE; tracking = null
                if (ok) Fire.Tap else null
            }
            else -> { reset(); null }
        }
    }

    private fun feedDoubleTap(ev: PointerEv): Fire? {
        if (!follows(ev)) return null
        return when (ev.phase) {
            PointerPhase.DOWN -> { beginDown(ev); null }
            PointerPhase.MOVE -> {
                if (state == State.POSSIBLE && dist(ev.x, ev.y, startX, startY) > GestureTuning.SLOP)
                    state = State.REJECTED
                null
            }
            PointerPhase.UP -> {
                val isTap = state == State.POSSIBLE &&
                    dist(ev.x, ev.y, startX, startY) <= GestureTuning.SLOP &&
                    ev.timeMs - startTime < GestureTuning.TAP_TIMEOUT_MS
                state = State.IDLE; tracking = null
                if (!isTap) { hasLastTap = false; return null }
                if (hasLastTap &&
                    ev.timeMs - lastTapTime < GestureTuning.DOUBLE_TAP_MS &&
                    dist(ev.x, ev.y, lastTapX, lastTapY) <= GestureTuning.SLOP) {
                    hasLastTap = false
                    return Fire.DoubleTap
                }
                lastTapTime = ev.timeMs; lastTapX = ev.x; lastTapY = ev.y
                hasLastTap = true
                null
            }
            else -> { reset(); null }
        }
    }

    private fun feedLongPress(ev: PointerEv): Fire? {
        if (!follows(ev)) return null
        return when (ev.phase) {
            PointerPhase.DOWN -> { beginDown(ev); longPressFired = false; null }
            PointerPhase.MOVE -> {
                if (state != State.POSSIBLE) return null
                if (dist(ev.x, ev.y, startX, startY) > GestureTuning.SLOP) {
                    state = State.REJECTED
                    return null
                }
                if (!longPressFired && ev.timeMs - startTime >= GestureTuning.LONG_PRESS_MS) {
                    longPressFired = true
                    state = State.IDLE; tracking = null
                    return Fire.LongPress
                }
                null
            }
            PointerPhase.UP -> {
                val ok = state == State.POSSIBLE && !longPressFired &&
                    dist(ev.x, ev.y, startX, startY) <= GestureTuning.SLOP &&
                    ev.timeMs - startTime >= GestureTuning.LONG_PRESS_MS
                state = State.IDLE; tracking = null
                if (ok) Fire.LongPress else null
            }
            else -> { reset(); null }
        }
    }

    private fun feedPan(ev: PointerEv): Fire? {
        if (!follows(ev)) return null
        return when (ev.phase) {
            PointerPhase.DOWN -> { beginDown(ev); sampleLen = 0; addSample(ev); null }
            PointerPhase.MOVE -> {
                if (state == State.POSSIBLE) {
                    if (dist(ev.x, ev.y, startX, startY) > GestureTuning.SLOP) {
                        state = State.ACCEPTED
                        lastX = ev.x; lastY = ev.y
                        addSample(ev)
                        return Fire.PanStart(ev.x - startX, ev.y - startY)
                    }
                    return null
                }
                if (state == State.ACCEPTED) {
                    val dx = ev.x - lastX; val dy = ev.y - lastY
                    lastX = ev.x; lastY = ev.y
                    addSample(ev)
                    return Fire.PanUpdate(dx, dy)
                }
                null
            }
            PointerPhase.UP -> {
                if (state != State.ACCEPTED) { state = State.IDLE; tracking = null; return null }
                state = State.IDLE; tracking = null
                addSample(ev)
                val (vx, vy) = velocity(ev.timeMs)
                val dx = ev.x - lastX; val dy = ev.y - lastY
                if (kind == GKind.SWIPE && max(abs(vx), abs(vy)) > GestureTuning.SWIPE_VELOCITY) {
                    val dir = if (abs(vx) >= abs(vy))
                        (if (vx > 0) SwipeDir.RIGHT else SwipeDir.LEFT)
                    else (if (vy > 0) SwipeDir.DOWN else SwipeDir.UP)
                    return Fire.Swipe(dir, vx, vy)
                }
                Fire.PanEnd(vx, vy, dx, dy)
            }
            else -> { reset(); null }
        }
    }

    private fun feedPinch(ev: PointerEv): Fire? {
        return when (ev.phase) {
            PointerPhase.DOWN -> { trackDown(ev); null }
            PointerPhase.MOVE -> {
                if (state != State.ACCEPTED || !trackMove(ev)) return null
                val a = ptrA ?: return null; val b = ptrB ?: return null
                if (initialDistance <= 0) return null
                Fire.Pinch(dist(a.x, a.y, b.x, b.y) / initialDistance)
            }
            PointerPhase.UP -> { trackUp(ev); null }
            else -> { reset(); null }
        }
    }

    private fun feedRotate(ev: PointerEv): Fire? {
        return when (ev.phase) {
            PointerPhase.DOWN -> { trackDown(ev); null }
            PointerPhase.MOVE -> {
                if (state != State.ACCEPTED || !trackMove(ev)) return null
                val a = ptrA ?: return null; val b = ptrB ?: return null
                val angle = atan2(b.y - a.y, b.x - a.x)
                val delta = wrapAngle(angle - lastAngle)
                lastAngle = angle
                Fire.Rotate(delta)
            }
            PointerPhase.UP -> { trackUp(ev); null }
            else -> { reset(); null }
        }
    }
}

/** The detector's callbacks append tags to `harness.gestures` — the vector's
 *  "gestures" prop enables recognizers exactly like the reference (each name
 *  installs that callback). */
class GestureArena(gestureNames: List<String>, e: Engine) {
    val recognizers = ArrayList<Recognizer>()
    private var log: (String) -> Unit = {}
    private var enabled: Set<String> = emptySet()

    init {
        val names = gestureNames.toSet()
        fun push(kind: GKind, enabled: Boolean) {
            if (enabled && recognizers.size < 8) recognizers.add(Recognizer(kind))
        }
        push(GKind.TAP, "tap" in names)
        push(GKind.DOUBLE_TAP, "double_tap" in names)
        push(GKind.LONG_PRESS, "long_press" in names)
        push(GKind.PAN, "pan_start" in names || "pan_update" in names || "pan_end" in names)
        push(GKind.SWIPE, "swipe" in names)
        push(GKind.PINCH, "pinch" in names)
        push(GKind.ROTATE, "rotate" in names)
        log = { tag -> e.gestureLog.add(tag) }
        enabled = names
    }

    fun feed(evIn: PointerEv) {
        // Physical-finger semantics: feed window coords (a scrollable
        // scrolling under a held finger must not corrupt deltas).
        val ev = PointerEv(evIn.phase, evIn.rawX, evIn.rawY, evIn.rawX, evIn.rawY, evIn.pointer, evIn.timeMs)
        if (ev.phase == PointerPhase.ENTER || ev.phase == PointerPhase.LEAVE ||
            ev.phase == PointerPhase.OUTSIDE_DOWN) {
            cancel()
            return
        }
        var twoFingerActive = false
        for (r in recognizers) {
            if (r.kind != GKind.PINCH && r.kind != GKind.ROTATE) continue
            when (val f = r.feed(ev)) {
                is Fire.Pinch -> log("pinch")
                is Fire.Rotate -> log("rotate")
                else -> {}
            }
            if (r.state == Recognizer.State.ACCEPTED) {
                twoFingerActive = true
                for (o in recognizers) {
                    if (o.kind == GKind.PINCH || o.kind == GKind.ROTATE) continue
                    o.reset()
                }
            }
        }
        if (twoFingerActive) return
        var tapFire = false
        var doubleTapFire = false
        var terminal: Fire? = null
        for (r in recognizers) {
            if (r.kind == GKind.PINCH || r.kind == GKind.ROTATE) continue
            when (val f = r.feed(ev)) {
                is Fire.Tap -> tapFire = true
                is Fire.DoubleTap -> doubleTapFire = true
                is Fire.PanStart -> if ("pan_start" in enabled) log("pan_start")
                is Fire.PanUpdate -> if ("pan_update" in enabled) log("pan_update")
                is Fire.LongPress, is Fire.PanEnd, is Fire.Swipe -> { if (terminal == null) terminal = f }
                else -> {}
            }
        }
        if (doubleTapFire) {
            log("double_tap")
        } else if (tapFire) {
            log("tap")
        } else terminal?.let { f ->
            when (f) {
                is Fire.LongPress -> if ("long_press" in enabled) log("long_press")
                is Fire.PanEnd -> if ("pan_end" in enabled) log("pan_end")
                is Fire.Swipe -> if ("swipe" in enabled) log("swipe:${f.dir.name.lowercase()}")
                else -> {}
            }
        }
    }

    fun cancel() { for (r in recognizers) r.reset() }

    fun tick(nowMs: Long) {
        for (r in recognizers) {
            when (r.tick(nowMs)) {
                is Fire.LongPress -> if ("long_press" in enabled) log("long_press")
                else -> {}
            }
        }
    }
}
