// Internationalization — Kotlin port of src/ui/i18n.zig: ARB locale tables,
// tr/trArgs/trPlural (CLDR categories for en/fr/ja/ar), number/date format
// data, and the process-global text direction.
package conf.compose

import kotlin.math.floor

enum class DateKind { short, medium, long }

class NumberOptions(
    var decimals: Int? = null,
    var percent: Boolean = false,
    var grouping: Boolean = true,
)

class Date(val year: Int, val month: Int, val day: Int)

class Locale(val tag: String) {
    var direction = Direction.LTR
    val messages = LinkedHashMap<String, String>()
    var decimalSep = "."
    var groupSep = ","
    var dateShort = "M/d/yy"
    var dateMedium = "MMM d, y"
    var dateLong = "MMMM d, y"
    var monthLong = arrayOf("January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December")
    var monthShort = arrayOf("Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

    /** Parse an ARB document into the message table ('@' keys skipped). */
    fun parseArb(json: String) {
        val doc = parseJson(json).obj ?: throw ConfError("InvalidArb")
        for ((k, v) in doc) {
            if (k.isEmpty() || k[0] == '@') continue
            val s = v.str ?: continue
            messages[k] = s
        }
    }

    /** Format a number per the locale (grouping, separators, percent). */
    fun formatNumber(value: Double, opts: NumberOptions): String {
        val sb = StringBuilder()
        var v = value
        if (v < 0) { sb.append('-'); v = -v }
        if (opts.percent) v *= 100
        // Shortest round-trip digits (Zig "{d}" on a float → the shortest
        // decimal that round-trips; JVM Double.toString is the same algo).
        val all = if (v == floor(v) && !v.isInfinite() && Math.abs(v) < 1e16)
            v.toLong().toString() else v.toString()
        var intPart = all
        var fracPart = ""
        val dot = all.indexOf('.')
        if (dot >= 0) { intPart = all.substring(0, dot); fracPart = all.substring(dot + 1) }
        if (opts.grouping && intPart.length > 3) {
            val len = intPart.length
            val rem = len % 3
            val firstN = if (rem == 0) 3 else rem
            sb.append(intPart.substring(0, firstN))
            var pos = firstN
            while (pos < len) {
                sb.append(groupSep)
                sb.append(intPart.substring(pos, pos + 3))
                pos += 3
            }
        } else sb.append(intPart)
        val d = opts.decimals
        if (d != null) {
            if (d > 0) {
                sb.append(decimalSep)
                for (i in 0 until d) sb.append(if (i < fracPart.length) fracPart[i] else '0')
            }
        } else if (fracPart.isNotEmpty()) {
            sb.append(decimalSep).append(fracPart)
        }
        if (opts.percent) sb.append('%')
        return sb.toString()
    }

    /** Format a date per the locale and kind (pattern tokens y/M/d). */
    fun formatDate(date: Date, kind: DateKind): String {
        val pattern = when (kind) {
            DateKind.short -> dateShort
            DateKind.medium -> dateMedium
            DateKind.long -> dateLong
        }
        val sb = StringBuilder()
        var i = 0
        while (i < pattern.length) {
            val ch = pattern[i]
            if (ch != 'y' && ch != 'M' && ch != 'd') { sb.append(ch); i++; continue }
            var j = i
            while (j < pattern.length && pattern[j] == ch) j++
            val n = j - i
            when (ch) {
                'y' -> if (n == 2) sb.append("%02d".format(Math.floorMod(date.year, 100)))
                       else sb.append(date.year)
                'M' -> {
                    val m = date.month - 1
                    when (n) {
                        1 -> sb.append(date.month)
                        2 -> sb.append("%02d".format(date.month))
                        3 -> sb.append(monthShort[m])
                        else -> sb.append(monthLong[m])
                    }
                }
                'd' -> sb.append(if (n >= 2) "%02d".format(date.day) else date.day.toString())
            }
            i = j
        }
        return sb.toString()
    }
}

/** Built-in format data for en/fr/ja/ar (unknown tags keep en defaults). */
fun applyFormatData(loc: Locale) {
    val base = loc.tag.substringBefore('-')
    when (base) {
        "fr" -> {
            loc.decimalSep = ","; loc.groupSep = " "
            loc.dateShort = "dd/MM/y"; loc.dateMedium = "d MMM y"; loc.dateLong = "d MMMM y"
            loc.monthLong = arrayOf("janvier", "février", "mars", "avril", "mai", "juin",
                "juillet", "août", "septembre", "octobre", "novembre", "décembre")
            loc.monthShort = arrayOf("janv.", "févr.", "mars", "avr.", "mai", "juin",
                "juil.", "août", "sept.", "oct.", "nov.", "déc.")
        }
        "ja" -> {
            loc.dateShort = "y/MM/dd"; loc.dateMedium = "y/MM/dd"; loc.dateLong = "y年M月d日"
            val months = Array(12) { "${it + 1}月" }
            loc.monthLong = months; loc.monthShort = months
        }
        "ar" -> {
            loc.direction = Direction.RTL
            loc.dateShort = "d/M/y"; loc.dateMedium = "d MMM y"; loc.dateLong = "d MMMM y"
            val months = arrayOf("يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
                "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر")
            loc.monthLong = months; loc.monthShort = months
        }
    }
}

enum class PluralCategory { zero, one, two, few, many, other }

/** CLDR plural category for a locale tag and count (en/fr/ja/ar; the default
 *  rule is one/other like English). */
fun pluralCategory(tag: String, n: Long): PluralCategory {
    val base = tag.substringBefore('-')
    when (base) {
        "fr" -> return if (n >= 0 && n < 2) PluralCategory.one else PluralCategory.other
        "ja" -> return PluralCategory.other
        "ar" -> {
            if (n == 0L) return PluralCategory.zero
            if (n == 1L) return PluralCategory.one
            if (n == 2L) return PluralCategory.two
            if (n > 0) {
                val m100 = Math.floorMod(n, 100)
                if (m100 in 3..10) return PluralCategory.few
                if (m100 in 11..99) return PluralCategory.many
            }
            return PluralCategory.other
        }
    }
    return if (n == 1L) PluralCategory.one else PluralCategory.other
}

class PluralBranch(var exact: Long? = null, var category: PluralCategory? = null, var text: String = "")

class PluralMsg {
    val branches = ArrayList<PluralBranch>()
    var prefix = ""
    var suffix = ""
}

/** Parse an ARB plural block `{count, plural, =0 {...} one {...} other {...}}`. */
fun parsePlural(msg: String): PluralMsg? {
    val p = msg.indexOf(", plural,")
    if (p < 0) return null
    val open = msg.lastIndexOf('{', p)
    if (open < 0) return null
    val out = PluralMsg()
    out.prefix = msg.substring(0, open)
    var i = p + ", plural,".length
    while (i < msg.length) {
        while (i < msg.length && msg[i] == ' ') i++
        if (i >= msg.length) return null
        if (msg[i] == '}') {
            out.suffix = msg.substring(i + 1)
            return if (out.branches.isNotEmpty()) out else null
        }
        val branch = PluralBranch()
        if (msg[i] == '=') {
            i++
            var num = 0L; var neg = false
            if (i < msg.length && msg[i] == '-') { neg = true; i++ }
            while (i < msg.length && msg[i].isDigit()) { num = num * 10 + (msg[i] - '0'); i++ }
            branch.exact = if (neg) -num else num
        } else {
            val start = i
            while (i < msg.length && msg[i] != ' ' && msg[i] != '{') i++
            branch.category = try { PluralCategory.valueOf(msg.substring(start, i)) } catch (e: Exception) { null }
        }
        while (i < msg.length && msg[i] == ' ') i++
        if (i >= msg.length || msg[i] != '{') return null
        i++
        val textStart = i
        var depth = 1
        while (i < msg.length && depth > 0) {
            if (msg[i] == '{') depth++
            if (msg[i] == '}') depth--
            i++
        }
        if (depth != 0) return null
        branch.text = msg.substring(textStart, i - 1)
        out.branches.add(branch)
    }
    return if (out.branches.isNotEmpty()) out else null
}

/** Select the branch: exact =N first, then the CLDR category, then `other`. */
fun selectPlural(msg: PluralMsg, tag: String, count: Long): String? {
    for (b in msg.branches) if (b.exact != null && b.exact == count) return b.text
    val cat = pluralCategory(tag, count)
    for (b in msg.branches) if (b.category == cat) return b.text
    for (b in msg.branches) if (b.category == PluralCategory.other) return b.text
    return null
}

/** Interpolate `{name}` placeholders from an args map. Unknown placeholders
 *  are left as-is. */
fun interpolate(msg: String, args: Map<String, String>): String {
    val sb = StringBuilder()
    var i = 0
    while (i < msg.length) {
        if (msg[i] == '{') {
            val close = msg.indexOf('}', i)
            if (close >= 0) {
                val name = msg.substring(i + 1, close)
                val v = args[name]
                if (v != null) { sb.append(v); i = close + 1; continue }
            }
        }
        sb.append(msg[i]); i++
    }
    return sb.toString()
}

/** Interpolate a plural branch: `#` and `{count}` expand to the count. */
fun interpolatePlural(branch: String, count: Long, args: Map<String, String>): String {
    val sb = StringBuilder()
    val countStr = count.toString()
    var i = 0
    while (i < branch.length) {
        if (branch[i] == '#') { sb.append(countStr); i++; continue }
        if (branch[i] == '{') {
            val close = branch.indexOf('}', i)
            if (close >= 0) {
                val name = branch.substring(i + 1, close)
                if (name == "count") { sb.append(countStr); i = close + 1; continue }
                val v = args[name]
                if (v != null) { sb.append(v); i = close + 1; continue }
            }
        }
        sb.append(branch[i]); i++
    }
    return sb.toString()
}

class I18n(fallbackTag: String) {
    val locales = LinkedHashMap<String, Locale>()
    val fallback = fallbackTag
    var current: Locale? = null
    val localeSig = KSignal("")
    var onDirectionChanged: (() -> Unit)? = null

    fun addLocale(loc: Locale) {
        var replacedCurrent: Direction? = null
        locales[loc.tag]?.let { old ->
            locales.remove(loc.tag)
            if (current === old) {
                replacedCurrent = old.direction
                current = loc
            }
        }
        locales[loc.tag] = loc
        applyFormatData(loc)
        if (current == null) current = loc
        if (replacedCurrent != null) {
            localeSig.emit()
            if (loc.direction != replacedCurrent) onDirectionChanged?.invoke()
        } else if (loc.tag == fallback) {
            localeSig.emit()
        }
    }

    fun addArb(tag: String, arbJson: String, dir: Direction) {
        val loc = Locale(tag)
        loc.parseArb(arbJson)
        loc.direction = dir
        addLocale(loc)
    }

    fun setLocale(tag: String) {
        val loc = locales[tag] ?: throw ConfError("UnknownLocale")
        val oldDir = direction()
        current = loc
        localeSig.set(loc.tag)
        if (direction() != oldDir) onDirectionChanged?.invoke()
    }

    fun locale() = current
    fun direction(): Direction = current?.direction ?: Direction.LTR

    /** Resolve a message: current locale → fallback → the key itself. */
    fun tr(key: String): String {
        current?.messages?.get(key)?.let { return it }
        locales[fallback]?.messages?.get(key)?.let { return it }
        return key
    }

    fun trArgs(key: String, args: Map<String, String>) = interpolate(tr(key), args)

    private fun trTagged(key: String): Pair<String, String> {
        current?.messages?.get(key)?.let { return it to current!!.tag }
        locales[fallback]?.messages?.get(key)?.let { return it to fallback }
        return key to (current?.tag ?: "")
    }

    /** Resolve a plural message for a count (ARB block + CLDR rules). */
    fun trPlural(key: String, count: Long, args: Map<String, String>): String {
        val (msg, tag) = trTagged(key)
        parsePlural(msg)?.let { pm ->
            val branch = selectPlural(pm, tag, count) ?: return msg
            if (pm.prefix.isEmpty() && pm.suffix.isEmpty()) {
                return interpolatePlural(branch, count, args)
            }
            return interpolate(pm.prefix, args) +
                interpolatePlural(branch, count, args) +
                interpolate(pm.suffix, args)
        }
        return interpolate(msg, args)
    }
}
