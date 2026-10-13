/// Klaxon Conformance Suite — Flutter adapter entry point.
///
/// Runs the framework-neutral corpus (conformance/tests/*.json) through the
/// real Flutter widget/layout/gesture/raster pipeline in a headless
/// `flutter test`. Mirrors the native runner's output: per-test PASS/FAIL,
/// per-domain tallies, a score line, and a JSON report.
///
/// Env overrides:
///   KX_TESTS_DIR   — corpus dir   (default ../../tests = conformance/tests)
///   KX_RESULTS_DIR — report dir   (default ../../results/flutter)
///   KX_FILTER      — substring filter on test ids
///   KX_VERBOSE=1   — print passing tests too
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:klaxon_conformance_flutter/runner.dart';

// The fixed domain order — same as conformance_main.zig's DOMAIN_FILES.
const kDomainFiles = [
  'layout.json',
  'paint.json',
  'gestures.json',
  'i18n.json',
  'focus.json',
  'a11y.json',
  'navigation.json',
  'scrolling.json',
  'state.json',
];

String _timestampIso8601() {
  final t = DateTime.now().toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}-${two(t.minute)}-${two(t.second)}';
}

void main() {
  testWidgets('klaxon conformance corpus (flutter adapter)', (tester) async {
    final testsDir = Platform.environment['KX_TESTS_DIR'] ?? '../../tests';
    final resultsDir = Platform.environment['KX_RESULTS_DIR'] ?? '../../results/flutter';
    final filter = Platform.environment['KX_FILTER'];
    final verbose = Platform.environment['KX_VERBOSE'] == '1';

    final results = <KxResult>[];
    final byDomain = <String, List<int>>{}; // domain → [pass, fail]

    for (final file in kDomainFiles) {
      final path = '$testsDir/$file';
      String doc;
      try {
        doc = File(path).readAsStringSync();
      } on FileSystemException {
        stdout.writeln('  (skipped $file)');
        continue;
      }
      final parsed = jsonDecode(doc);
      final tests = (parsed is Map ? parsed['tests'] : null) as List? ?? const [];
      for (final tv in tests.whereType<Map>()) {
        final vec = tv.cast<String, dynamic>();
        if (filter != null && !vec['id'].toString().contains(filter)) continue;
        final res = await runVector(tester, vec);
        results.add(res);
        final d = byDomain.putIfAbsent(res.domain, () => [0, 0]);
        d[res.passed ? 0 : 1] += 1;
        if (verbose || !res.passed) {
          final tag = res.passed ? 'PASS' : 'FAIL';
          final tails = res.failures.map((f) => ' — $f').join();
          stdout.writeln('$tag ${res.id}$tails');
        }
      }
    }

    // --- console summary (native format) ---
    var total = 0, passed = 0;
    for (final r in results) {
      total += 1;
      if (r.passed) passed += 1;
    }
    for (final e in byDomain.entries) {
      final p = e.value[0], f = e.value[1];
      stdout.writeln('  ${e.key.padRight(11)} $p/${p + f}');
    }
    final score = total == 0 ? 0.0 : passed * 100.0 / total;
    stdout.writeln('klaxon conformance (flutter): $passed/$total passed '
        '(${score.toStringAsFixed(1)}%)');

    // --- JSON report (same shape as conformance_main.zig's) ---
    final ts = _timestampIso8601();
    final report = <String, dynamic>{
      'framework': 'flutter',
      'version': 'p0',
      'timestamp': ts,
      'score_pct': double.parse(score.toStringAsFixed(2)),
      'by_domain': {
        for (final e in byDomain.entries)
          e.key: {'pass': e.value[0], 'fail': e.value[1]},
      },
      'tests': [
        for (final r in results)
          {
            'id': r.id,
            'domain': r.domain,
            'rule': r.rule,
            'passed': r.passed,
            if (r.failures.isNotEmpty) 'failures': r.failures,
          },
      ],
    };
    if (results.isNotEmpty) {
      final dir = Directory(resultsDir)..createSync(recursive: true);
      final out = '${dir.path}/results-$ts.json';
      File(out).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      stdout.writeln('  report: $out');
    }

    expect(results, isNotEmpty);
    // The suite's score is reported, not asserted: genuine framework-semantic
    // divergences are recorded in the report + MAPPING.md, never hidden.
  });
}
