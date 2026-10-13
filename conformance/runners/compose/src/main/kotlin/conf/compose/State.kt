// Reactive state — Kotlin port of src/ui/state.zig: SignalBase + Signal(T),
// TextSignal (the 1 MiB cap), Effect (dependency tracking) and Memo.
package conf.compose

/** Subscriber = effect re-run | node dirty-mark | plain callback. */
class Subscriber(private val fn: () -> Unit) {
    fun fire() = fn()
    companion object {
        fun ofEffect(e: Effect) = Subscriber { e.run() }
        fun ofNode(n: KNode) = Subscriber { n.markDirty() }
        fun ofCallback(cb: () -> Unit) = Subscriber(cb)
    }
}

open class SignalBase {
    var version: Long = 0
    val subscribers = ArrayList<Subscriber>()

    fun subscribe(sub: Subscriber) { subscribers.add(sub) }
    fun unsubscribe(sub: Subscriber) { subscribers.removeAll { it === sub } }

    /** Iterate a snapshot: subscribers may (un)subscribe during notify.
     *  Revalidate each entry — an earlier subscriber may have destroyed a
     *  later one's owner (the widget deinit unsubscribes, but the stale
     *  snapshot entry would still run). */
    fun notifySubs() {
        version += 1
        val snapshot = subscribers.toList()
        for (sub in snapshot) {
            if (subscribers.any { it === sub }) sub.fire()
        }
    }
}

/** A reactive value. Inside an Effect, `get` tracks a dependency. */
class KSignal<T>(initial: T) {
    val base = SignalBase()
    var value: T = initial
        private set

    fun get(): T {
        Harness.currentEffect?.track(base)
        return value
    }
    fun peek(): T = value
    fun set(newValue: T) {
        if (value == newValue) return
        value = newValue
        base.notifySubs()
    }
    fun emit() = base.notifySubs()
    fun subscribe(sub: Subscriber) = base.subscribe(sub)
    fun unsubscribe(sub: Subscriber) = base.unsubscribe(sub)
}

/** A reactive, growable text channel. Input over max_len is REJECTED
 *  (ConfError "TextTooLong") — never truncated. */
class TextSignal(initial: String) {
    val base = SignalBase()
    var value: String = initial
        private set

    init {
        if (initial.length > MAX_LEN) throw ConfError("TextTooLong")
    }

    fun get(): String {
        Harness.currentEffect?.track(base)
        return value
    }
    fun peek() = value
    fun set(newText: String) {
        if (newText.length > MAX_LEN) throw ConfError("TextTooLong")
        if (value == newText) return
        value = newText
        base.notifySubs()
    }
    fun emit() = base.notifySubs()
    fun subscribe(sub: Subscriber) = base.subscribe(sub)
    fun unsubscribe(sub: Subscriber) = base.unsubscribe(sub)

    companion object { const val MAX_LEN = 1 shl 20 }
}

/** Runs a fn, re-runs when any read dependency changes. */
class Effect(private val body: () -> Unit) {
    val dependencies = ArrayList<SignalBase>()

    fun run() {
        for (dep in dependencies) dep.unsubscribe(subscriber)
        dependencies.clear()
        val prev = Harness.currentEffect
        Harness.currentEffect = this
        try {
            body()
        } finally {
            Harness.currentEffect = prev
        }
    }

    fun track(base: SignalBase) {
        if (dependencies.any { it === base }) return
        dependencies.add(base)
        base.subscribe(subscriber)
    }

    private val subscriber = Subscriber.ofEffect(this)

    fun deinit() {
        for (dep in dependencies) dep.unsubscribe(subscriber)
        dependencies.clear()
    }
}

/** Cached derived value; recomputes when its dependencies change and
 *  notifies its own dependents. */
class Memo(private val compute: () -> Long) {
    val base = SignalBase()
    var cache: Long = 0
        private set

    private val effect = Effect {
        cache = compute()
        base.notifySubs()
    }

    init { effect.run() } // initial compute

    fun get(): Long {
        Harness.currentEffect?.track(base)
        return cache
    }
    fun deinit() = effect.deinit()
}
