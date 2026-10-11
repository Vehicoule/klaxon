#!/usr/bin/env python3
# bench-report.py — Phase 4c.5: merge all benchmark JSON reports under
# bench/results/ into one HTML report (+ a console table).
#
# Layout read:
#   bench/results/<ts>.json            -> framework "klaxon" (scripts/bench.sh)
#   bench/results/<framework>/<ts>.json -> framework = directory name
# When several reports exist for one framework, the newest is used.
#
# Usage: scripts/bench-report.py [--out bench/report.html]
# Stdlib only.
import argparse
import glob
import html
import json
import os
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "bench", "results")

SCENE_ORDER = [
    "hello", "scroll_10k", "text_cjk", "glass_blur", "anim_100",
    "gallery", "resize", "input_ime", "video_playback",
]
METRICS = [
    ("fps", "fps", "{:.1f}"),
    ("frame_time_avg_ms", "avg ms", "{:.2f}"),
    ("frame_time_p99_ms", "p99 ms", "{:.2f}"),
    ("draw_calls_per_frame", "draws", "{:.0f}"),
    ("rss_mb", "rss MB", "{:.1f}"),
    ("ttff_ms", "ttff ms", "{:.1f}"),
]


def load_reports():
    """Return {framework: {scene: metrics-dict, ...}, ...} plus metadata."""
    reports = {}  # framework -> (timestamp, path, data)
    # Flat files = Klaxon's own runner.
    for path in glob.glob(os.path.join(RESULTS, "*.json")):
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        ts = data.get("timestamp", "")
        if "klaxon" not in reports or ts > reports["klaxon"][0]:
            reports["klaxon"] = (ts, path, data)
    # Per-framework directories.
    for fw_dir in sorted(glob.glob(os.path.join(RESULTS, "*"))):
        if not os.path.isdir(fw_dir):
            continue
        fw = os.path.basename(fw_dir)
        for path in glob.glob(os.path.join(fw_dir, "*.json")):
            try:
                with open(path) as f:
                    data = json.load(f)
            except (OSError, json.JSONDecodeError):
                continue
            ts = data.get("timestamp", "")
            if fw not in reports or ts > reports[fw][0]:
                reports[fw] = (ts, path, data)
    out = {}
    for fw, (ts, path, data) in reports.items():
        scenes = {}
        for s in data.get("scenes", []):
            scenes[s["name"]] = s
        out[fw] = {
            "scenes": scenes,
            "binary_size_bytes": data.get("binary_size_bytes", 0),
            "timestamp": ts,
            "path": os.path.relpath(path, ROOT),
        }
    return out


def scene_list(reports):
    names = []
    for s in SCENE_ORDER:
        if any(s in r["scenes"] for r in reports.values()):
            names.append(s)
    for fw in reports:
        for s in reports[fw]["scenes"]:
            if s not in names:
                names.append(s)
    return names


def fmt(v, spec):
    try:
        return spec.format(float(v))
    except (TypeError, ValueError):
        return "-"


def console_table(reports, scenes):
    fw_names = sorted(reports)
    lines = []
    header = "scene".ljust(15) + "".join(fw.rjust(12) for fw in fw_names)
    lines.append(header)
    lines.append("-" * len(header))
    for s in scenes:
        row = s.ljust(15)
        for fw in fw_names:
            sc = reports[fw]["scenes"].get(s)
            row += (fmt(sc["fps"], "{:.1f}") if sc else "-").rjust(12)
        lines.append(row)
    lines.append("")
    lines.append("binary size".ljust(15) + "".join(
        (f"{reports[fw]['binary_size_bytes']/1e6:.2f} MB" if reports[fw]["binary_size_bytes"] else "-").rjust(12)
        for fw in fw_names))
    lines.append("rss (gallery)".ljust(15) + "".join(
        (fmt(reports[fw]["scenes"]["gallery"]["rss_mb"], "{:.1f}") if reports[fw]["scenes"].get("gallery") else "-").rjust(12)
        for fw in fw_names))
    return "\n".join(lines)


def html_report(reports, scenes):
    fw_names = sorted(reports)
    esc = html.escape
    parts = [
        "<!DOCTYPE html><html><head><meta charset='utf-8'>",
        "<title>Klaxon benchmarks — cross-framework report</title>",
        "<style>",
        "body{font-family:-apple-system,Segoe UI,Roboto,sans-serif;margin:2rem;color:#1a1a2e;background:#fafaff}",
        "h1{font-size:1.4rem} h2{font-size:1.1rem;margin-top:2rem}",
        "table{border-collapse:collapse;margin:1rem 0} th,td{border:1px solid #d5d5e5;padding:4px 10px;text-align:right;font-size:.85rem}",
        "th{background:#ececf6} td:first-child,th:first-child{text-align:left}",
        "tr:nth-child(even){background:#f4f4fa}",
        ".bar{height:10px;background:#4f6ef7;border-radius:2px;display:inline-block;vertical-align:middle}",
        ".meta{color:#666;font-size:.8rem}",
        "</style></head><body>",
        "<h1>Klaxon benchmarks — cross-framework report</h1>",
        f"<p class='meta'>Generated {datetime.now().isoformat(timespec='seconds')} — "
        f"{len(fw_names)} frameworks, {len(scenes)} scenes. fps = 1000/avg frame work time (unpaced).</p>",
    ]
    # Summary table: fps per framework x scene, with bars scaled to the best.
    parts.append("<h2>fps (higher is better)</h2><table><tr><th>scene</th>")
    for fw in fw_names:
        parts.append(f"<th>{esc(fw)}</th>")
    parts.append("</tr>")
    for s in scenes:
        parts.append(f"<tr><td>{esc(s)}</td>")
        fps_vals = []
        for fw in fw_names:
            sc = reports[fw]["scenes"].get(s)
            fps_vals.append(float(sc["fps"]) if sc and sc.get("fps") else 0.0)
        best = max(fps_vals) if fps_vals else 0.0
        for fw, fps in zip(fw_names, fps_vals):
            if fps > 0:
                w = max(2, int(100 * fps / best)) if best else 2
                cell = f"{fps:.1f} <span class='bar' style='width:{w}px'></span>"
            else:
                cell = "-"
            parts.append(f"<td>{cell}</td>")
        parts.append("</tr>")
    parts.append("</table>")

    # Detailed metrics per framework.
    for fw in fw_names:
        r = reports[fw]
        parts.append(f"<h2>{esc(fw)}</h2>")
        parts.append(f"<p class='meta'>report: {esc(r['path'])} — {esc(r['timestamp'])} — "
                     f"binary {r['binary_size_bytes']/1e6:.2f} MB</p>")
        parts.append("<table><tr><th>scene</th>")
        for _, label, _ in METRICS:
            parts.append(f"<th>{esc(label)}</th>")
        parts.append("</tr>")
        for s in scenes:
            sc = r["scenes"].get(s)
            if not sc:
                continue
            parts.append(f"<tr><td>{esc(s)}</td>")
            for key, _, spec in METRICS:
                parts.append(f"<td>{fmt(sc.get(key), spec)}</td>")
            parts.append("</tr>")
        parts.append("</table>")
    parts.append("</body></html>")
    return "\n".join(parts)


def main():
    ap = argparse.ArgumentParser(description="Merge Klaxon benchmark JSONs into an HTML report")
    ap.add_argument("--out", default=os.path.join(ROOT, "bench", "report.html"))
    args = ap.parse_args()

    reports = load_reports()
    if not reports:
        raise SystemExit(f"no reports found under {RESULTS}")
    scenes = scene_list(reports)

    print(console_table(reports, scenes))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(html_report(reports, scenes))
    print(f"\nwrote {os.path.relpath(args.out, ROOT)}")


if __name__ == "__main__":
    main()
