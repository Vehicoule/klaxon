// Klaxon bench — Flutter comparison runner (roadmap Phase 4c.4).
//
// Renders the same 9 scenes as Klaxon's own bench (src/bench.zig) through
// Flutter, collects the same metrics, and emits the same JSON report so the
// two frameworks can be compared head-to-head.
//
// Usage:
//   klaxon_bench [scene]     run one scene (e.g. `klaxon_bench hello`)
//   klaxon_bench             run all 9 scenes, in bench order
//
// The JSON report is printed to stdout and also written to
// bench/results/flutter/<ISO8601-timestamp>.json (relative to the CWD;
// override the directory with KLAXON_BENCH_OUT_DIR). Progress goes to stderr.
// See README.md for the methodology and the known non-parities.

import 'dart:io';

import 'package:flutter/material.dart';

import 'harness.dart';
import 'scenes/scenes.dart';

Future<void> main(List<String> arguments) async {
  // Keep the JSON stream on stdout clean (Klaxon's bench contract: progress
  // and errors go to stderr). Flutter's default error dump and debugPrint go
  // to stdout via print() — reroute both to stderr.
  FlutterError.onError = (FlutterErrorDetails details) {
    stderr.writeln('flutter error: ${details.exceptionAsString()}');
    final StackTrace? stack = details.stack;
    if (stack != null) stderr.writeln(stack);
  };
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) stderr.writeln(message);
  };
  final List<String> selected;
  if (arguments.isNotEmpty) {
    if (!kSceneNames.contains(arguments[0])) {
      stderr.writeln(
          "klaxon bench (flutter): unknown scene '${arguments[0]}' — valid scenes:");
      stderr.writeln('  ${kSceneNames.join(' ')}');
      exit(1);
    }
    selected = <String>[arguments[0]];
  } else {
    selected = kSceneNames;
  }
  final List<BenchScene> scenes =
      <BenchScene>[for (final String n in selected) createScene(n)];
  WidgetsFlutterBinding.ensureInitialized();
  runApp(BenchHarness(scenes: scenes, onAllDone: _finish));
}

void _finish(List<SceneMetrics> results) {
  final String json = formatReport(results);
  // Report file: <ISO8601-timestamp>.json — colons in the timestamp are
  // replaced with '-' for filesystem safety.
  final String outDir =
      Platform.environment['KLAXON_BENCH_OUT_DIR'] ?? 'bench/results/flutter';
  final String ts = iso8601Utc(DateTime.now());
  final String fileName = ts.replaceAll(':', '-');
  try {
    Directory(outDir).createSync(recursive: true);
    File('$outDir/$fileName.json').writeAsStringSync(json);
    stderr.writeln(
        'klaxon bench (flutter): report written to $outDir/$fileName.json');
  } catch (e) {
    stderr.writeln('klaxon bench (flutter): cannot write report: $e');
  }
  writeStdout(json);
  exit(0);
}

/// Write the report to stdout — synchronous, the same pattern as
/// bench_main.zig's writeStdout (fopen/fwrite on /dev/stdout). An async
/// `stdout.flush()` can race `exit()` and lose the report when stdout is
/// redirected to a file.
void writeStdout(String json) {
  try {
    final RandomAccessFile f = File('/dev/stdout').openSync(mode: FileMode.append);
    try {
      f.writeStringSync(json);
    } finally {
      f.closeSync();
    }
  } catch (_) {
    stdout.write(json); // best-effort fallback
  }
}

/// JSON report — the 4c.3 output contract, same shape as src/bench_main.zig:
/// { "scenes": [ { "name", "fps", "frame_time_avg_ms", "frame_time_p50_ms",
///                 "frame_time_p99_ms", "draw_calls_per_frame", "rss_mb",
///                 "ttff_ms", "frames_rendered" } ],
///   "binary_size_bytes": N, "timestamp": "YYYY-MM-DDTHH:MM:SSZ" }
String formatReport(List<SceneMetrics> results) {
  final StringBuffer buf = StringBuffer();
  buf.write('{\n  "scenes": [\n');
  for (int i = 0; i < results.length; i++) {
    if (i > 0) buf.write(',\n');
    final SceneMetrics m = results[i];
    buf.write('    {\n');
    buf.write('      "name": "${m.name}",\n');
    buf.write('      "fps": ${m.fps.toStringAsFixed(1)},\n');
    buf.write('      "frame_time_avg_ms": ${m.frameTimeAvgMs.toStringAsFixed(1)},\n');
    buf.write('      "frame_time_p50_ms": ${m.percentile(50).toStringAsFixed(1)},\n');
    buf.write('      "frame_time_p99_ms": ${m.percentile(99).toStringAsFixed(1)},\n');
    buf.write('      "draw_calls_per_frame": ${m.drawCallsPerFrame},\n');
    buf.write('      "rss_mb": ${m.rssMb.toStringAsFixed(1)},\n');
    buf.write('      "ttff_ms": ${m.ttffMs.toStringAsFixed(1)},\n');
    buf.write('      "frames_rendered": ${m.framesRendered}\n');
    buf.write('    }');
  }
  buf.write('\n  ],\n');
  buf.write('  "binary_size_bytes": ${binarySizeBytes()},\n');
  buf.write('  "timestamp": "${iso8601Utc(DateTime.now())}"\n');
  buf.write('}\n');
  return buf.toString();
}

/// Size of the running .app's main executable in bytes. The Flutter engine
/// itself lives in libFlutterMacOS.framework (not counted) — see README
/// "binary_size_bytes" for the comparison caveat vs Klaxon's static binary.
int binarySizeBytes() {
  try {
    return File(Platform.resolvedExecutable).lengthSync();
  } catch (_) {
    return 0;
  }
}

/// Current UTC time, ISO 8601 ("2026-10-11T14:03:22Z") — bench_main.zig's
/// timestampIso8601 format.
String iso8601Utc(DateTime t) {
  final DateTime u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}
