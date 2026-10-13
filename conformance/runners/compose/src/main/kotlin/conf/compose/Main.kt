// Main — the Compose conformance runner entry point. A Kotlin port of
// src/conformance_main.zig: fixed domain order, per-domain tallies, the
// same console summary, the same JSON report shape ("framework":
// "compose"), written under conformance/results/compose/.
package conf.compose

import java.io.File
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/** The corpus is one file per domain — fixed names keep the run order (and
 *  the per-domain report) deterministic. */
val DOMAIN_FILES = listOf(
    "layout.json",
    "paint.json",
    "gestures.json",
    "i18n.json",
    "focus.json",
    "a11y.json",
    "navigation.json",
    "scrolling.json",
    "state.json",
)

class Options {
    var dir = "conformance/tests"
    var file: String? = null
    var filter: String? = null
    var out: String? = null
    var report = true
    var minScore = 0.0
    var verbose = false
}

class DomainScore {
    var pass = 0
    var fail = 0
}

fun main(args: Array<String>) {
    ComposeHost.installTextMeasure()
    val opts = optsFromArgs(args)

    val results = ArrayList<TestResult>()
    val byDomain = LinkedHashMap<String, DomainScore>()
    val skippedFiles = ArrayList<String>()

    if (opts.file != null) {
        runFile(File(opts.file!!), opts, results, byDomain)
    } else {
        for (name in DOMAIN_FILES) {
            val f = File(opts.dir, name)
            if (!f.isFile) {
                skippedFiles.add("$name (FileNotFound)")
                continue
            }
            runFile(f, opts, results, byDomain)
        }
    }

    // --- console summary ---
    var total = 0
    var passed = 0
    for (r in results) {
        total++
        if (r.passed) passed++
        if (opts.verbose || !r.passed) {
            val sb = StringBuilder()
            sb.append(if (r.passed) "PASS " else "FAIL ").append(r.id)
            for (f in r.failures) sb.append(" — ").append(f)
            println(sb)
        }
    }
    for ((dom, s) in byDomain) {
        println("  %-11s %d/%d".format(dom, s.pass, s.pass + s.fail))
    }
    val score = if (total == 0) 0.0 else passed * 100.0 / total
    println("klaxon conformance (compose): $passed/$total passed (${"%.1f".format(score)}%)")
    for (s in skippedFiles) println("  (skipped $s)")

    if (opts.report && total > 0) {
        val ts = timestampIso8601()
        val out = opts.out ?: "conformance/results/compose/results-$ts.json"
        val json = formatReport(results, byDomain, score, ts)
        try {
            val fo = File(out)
            fo.parentFile?.mkdirs()
            fo.writeText(json)
            println("  report: $out")
        } catch (t: Throwable) {
            System.err.println("klaxon conformance: cannot write '$out': ${t.message}")
            kotlin.system.exitProcess(2)
        }
    }

    if (score < opts.minScore) kotlin.system.exitProcess(1)
    if (total == 0) kotlin.system.exitProcess(1)
}

fun optsFromArgs(args: Array<String>): Options {
    val o = Options()
    for (arg in args) {
        when {
            arg.startsWith("--dir=") -> o.dir = arg.substring(6)
            arg.startsWith("--file=") -> o.file = arg.substring(7)
            arg.startsWith("--test=") -> o.filter = arg.substring(7)
            arg.startsWith("--out=") -> o.out = arg.substring(6)
            arg == "--no-report" -> o.report = false
            arg == "--verbose" -> o.verbose = true
            arg.startsWith("--min-score=") -> o.minScore = arg.substring(12).toDoubleOrNull() ?: o.minScore
        }
    }
    return o
}

fun runFile(f: File, opts: Options, results: MutableList<TestResult>, byDomain: MutableMap<String, DomainScore>) {
    val doc = try { parseJson(f.readText()) } catch (t: Throwable) {
        System.err.println("klaxon conformance: ${f.name}: ${t.message}")
        return
    }
    val tests = doc.prop("tests")?.arr ?: return
    for (tv in tests) {
        val id = tv.prop("id").strOr("?")
        val filt = opts.filter
        if (filt != null && !id.contains(filt)) continue
        val res = runTest(tv)
        results.add(res)
        val s = byDomain.getOrPut(res.domain) { DomainScore() }
        if (res.passed) s.pass++ else s.fail++
    }
}

/** The report contract (conformance/ADAPTERS.md §report): framework, score,
 *  per-domain tallies, per-test pass/fail + failures — the same shape the
 *  reference runner writes, with framework "compose". */
fun formatReport(results: List<TestResult>, byDomain: Map<String, DomainScore>, score: Double, ts: String): String {
    val sb = StringBuilder()
    sb.append("{\n  \"framework\": \"compose\",\n  \"version\": \"p0\",\n")
    sb.append("  \"timestamp\": \"$ts\",\n  \"score_pct\": %.2f,\n".format(score))
    sb.append("  \"by_domain\": {")
    var first = true
    for ((dom, s) in byDomain) {
        if (!first) sb.append(',')
        first = false
        sb.append("\n    \"$dom\": {\"pass\": ${s.pass}, \"fail\": ${s.fail}}")
    }
    sb.append("\n  },\n  \"tests\": [\n")
    results.forEachIndexed { i, r ->
        if (i > 0) sb.append(",\n")
        sb.append("    {\"id\": \"${r.id}\", \"domain\": \"${r.domain}\", \"rule\": \"${r.rule}\", \"passed\": ${r.passed}")
        if (r.failures.isNotEmpty()) {
            sb.append(", \"failures\": [")
            r.failures.forEachIndexed { j, f ->
                if (j > 0) sb.append(", ")
                JVal.appendJsonString(sb, f)
            }
            sb.append("]")
        }
        sb.append("}")
    }
    sb.append("\n  ]\n}\n")
    return sb.toString()
}

fun timestampIso8601(): String =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH-mm-ss")
        .withZone(ZoneOffset.UTC).format(Instant.now())
