// Navigation — Kotlin port of src/ui/navigator.zig: the UI-agnostic page
// stack (route patterns, imperative navigation, deep links). Page nodes are
// built by the harness; the corpus asserts stack shape + change events only.
package conf.compose

const val MAX_PARAMS = 8

class Params {
    val items = ArrayList<Pair<String, String>>()
    fun get(key: String): String? {
        for (it in items) if (it.first == key) return it.second
        return null
    }
    fun add(key: String, value: String): Boolean {
        if (items.size >= MAX_PARAMS) return false
        items.add(key to value)
        return true
    }
}

class Route(val pattern: String, val path: String, val params: Params, val transition: Transition)
enum class Transition { none, slide, slide_up, fade, scale }
enum class ChangeKind { push, pop, replace, reset }

fun parseTransition(s: String) = when (s) {
    "none" -> Transition.none; "slide_up" -> Transition.slide_up
    "fade" -> Transition.fade; "scale" -> Transition.scale
    else -> Transition.slide
}

class RouteDef(val pattern: String, val builder: (Route) -> KNode, val transition: Transition)
class Page(val id: Long, val route: Route, val node: KNode)

class Navigator {
    val pages = ArrayList<Page>()
    val routes = ArrayList<RouteDef>()
    var onChange: ((ChangeKind) -> Unit)? = null
    var nextId: Long = 1

    fun depth() = pages.size
    fun canPop() = pages.size > 1
    fun current(): Page? = pages.lastOrNull()
    fun containsPage(id: Long) = pages.any { it.id == id }

    fun define(pattern: String, builder: (Route) -> KNode, transition: Transition) {
        routes.add(RouteDef(pattern, builder, transition))
    }

    /** Push a route by pattern; the concrete path comes from pattern+params. */
    fun push(pattern: String, params: List<Pair<String, String>>) {
        val def = routes.find { it.pattern == pattern } ?: throw ConfError("UnknownRoute")
        val path = buildPath(pattern, params)
        pushDef(def, path, params)
    }

    /** Push a concrete path (deep links and cold starts). */
    fun pushPath(path: String, params: List<Pair<String, String>>) {
        val matched = Params()
        val def = routes.find { matchPattern(it.pattern, path, matched) } ?: throw ConfError("UnknownRoute")
        for (p in params) if (!matched.add(p.first, p.second)) throw ConfError("TooManyParams")
        pushDef(def, path, matched.items.toList())
    }

    /** Deep link: "klaxon://anime/42?tab=2" (scheme optional). Navigating to
     *  the route already on top is a no-op. */
    fun navigateTo(uri: String) {
        val (path, query) = parseUri(uri) ?: throw ConfError("InvalidUri")
        val params = Params()
        val def = routes.find { matchPattern(it.pattern, path, params) } ?: throw ConfError("UnknownRoute")
        var q = query
        while (q.isNotEmpty()) {
            val amp = q.indexOf('&')
            val pair = if (amp >= 0) q.substring(0, amp) else q
            q = if (amp >= 0) q.substring(amp + 1) else ""
            val eq = pair.indexOf('=')
            if (eq < 0) throw ConfError("InvalidUri")
            if (!params.add(pair.substring(0, eq), pair.substring(eq + 1))) throw ConfError("TooManyParams")
        }
        current()?.let { if (it.route.path == path) return }
        pushDef(def, path, params.items.toList())
    }

    fun onBack() = pop()

    fun pop(): Boolean {
        if (!canPop()) return false
        pages.removeAt(pages.size - 1)
        notify(ChangeKind.pop)
        return true
    }

    /** Replace the top page (same depth). On an empty stack this is a push. */
    fun replace(pattern: String, params: List<Pair<String, String>>) {
        if (pages.isEmpty()) return push(pattern, params)
        val def = routes.find { it.pattern == pattern } ?: throw ConfError("UnknownRoute")
        val path = buildPath(pattern, params)
        val newPage = buildPage(def, path, params)
        pages[pages.size - 1] = newPage
        notify(ChangeKind.replace)
    }

    fun popToRoot() {
        if (pages.size <= 1) return
        while (pages.size > 1) pages.removeAt(pages.size - 1)
        notify(ChangeKind.reset)
    }

    private fun pushDef(def: RouteDef, path: String, params: List<Pair<String, String>>) {
        pages.add(buildPage(def, path, params))
        notify(ChangeKind.push)
    }

    private fun buildPage(def: RouteDef, path: String, params: List<Pair<String, String>>): Page {
        val owned = Params()
        for (p in params) if (!owned.add(p.first, p.second)) throw ConfError("TooManyParams")
        val route = Route(def.pattern, path, owned, def.transition)
        val node = def.builder(route)
        return Page(nextId++, route, node)
    }

    private fun notify(kind: ChangeKind) { onChange?.invoke(kind) }
}

fun buildPath(pattern: String, params: List<Pair<String, String>>): String {
    val segs = pattern.split('/')
    val out = StringBuilder()
    segs.forEachIndexed { i, seg ->
        if (i > 0) out.append('/')
        if (seg.length >= 2 && seg.first() == '{' && seg.last() == '}') {
            val key = seg.substring(1, seg.length - 1)
            val v = params.find { it.first == key }?.second ?: throw ConfError("MissingParam")
            out.append(v)
        } else out.append(seg)
    }
    return out.toString()
}

/** Match a path against a pattern; "{name}" segments capture into params. */
fun matchPattern(pattern: String, path: String, params: Params): Boolean {
    params.items.clear()
    val pit = pattern.split('/').iterator()
    val hit = path.split('/').iterator()
    while (true) {
        val pn = pit.hasNext(); val hn = hit.hasNext()
        if (!pn && !hn) return true
        if (!pn || !hn) return false
        val p = pit.next(); val h = hit.next()
        if (p.length >= 2 && p.first() == '{' && p.last() == '}') {
            if (!params.add(p.substring(1, p.length - 1), h)) return false
        } else if (p != h) return false
    }
}

/** Parse "scheme://path?query" (scheme optional). A trailing slash is
 *  stripped; null when there is no path. */
fun parseUri(uri: String): Pair<String, String>? {
    var rest = uri
    val schemeIdx = rest.indexOf("://")
    if (schemeIdx >= 0) rest = rest.substring(schemeIdx + 3)
    var path = rest
    var query = ""
    val qIdx = rest.indexOf('?')
    if (qIdx >= 0) { path = rest.substring(0, qIdx); query = rest.substring(qIdx + 1) }
    while (path.length > 1 && path.last() == '/') path = path.dropLast(1)
    if (path.isEmpty()) return null
    return path to query
}
