#!/usr/bin/env python3
"""fidelity_diff.py — pixel-diff the Klaxon vs Compose fidelity renders.

Reads P6 PPM pairs from fidelity/out/klaxon/<id>.ppm and
fidelity/out/compose/<id>.ppm (produced by `zig build fidelity` and
fidelity/compose/run.sh), computes a tolerant per-pixel diff, writes a
visualization PPM per scene, and emits fidelity/report.json +
fidelity/report.html.

Tolerance model (fidelity/README.md):
  * channel delta: a pixel mismatches when ANY of R/G/B differs by more
    than --channel-tol (default 8) — absorbs 1-LSB rounding noise from
    premultiplied-alpha readbacks on two different Skia builds.
  * edge erosion: pixels adjacent (1px, 8-connected) to a "strong edge"
    in EITHER image are forgiven — strong edge = luma gradient across a
    pixel boundary above --edge-tol (default 48). This forgives AA fringes
    around shapes/text where the two rasterizers legitimately differ by
    a sub-pixel, without forgiving whole-widget geometry/colour drift.
  * size mismatch: the overlapping region is diffed and every missing
    pixel in the smaller image counts as a mismatch.

Exit status: 0 when every scene that exists on BOTH sides was compared
(mismatch % is reported, not gated — the gate lives in
gates/thresholds.json), 2 when any scene is missing on one side or a
pair is unreadable.

Usage:
  tools/fidelity_diff.py [--klaxon-dir DIR] [--compose-dir DIR]
                         [--diff-dir DIR] [--report-dir DIR]
                         [--channel-tol N] [--edge-tol N]
                         [--scene SUBSTR]
Stdlib only — no PIL/numpy.
"""

import argparse
import json
import os
import sys

DEFAULT_CHANNEL_TOL = 8
DEFAULT_EDGE_TOL = 48


def read_ppm(path):
    """Parse a P6 PPM. Returns (w, h, bytearray of RGB triples)."""
    with open(path, "rb") as f:
        data = f.read()

    tokens = []
    i = 0
    n = len(data)
    # Header: magic, width, height, maxval — whitespace separated,
    # '#' comments allowed after the magic.
    while len(tokens) < 4:
        while i < n and data[i:i + 1].isspace():
            i += 1
        if i < n and data[i:i + 1] == b"#":
            while i < n and data[i:i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < n and not data[j:j + 1].isspace():
            j += 1
        tokens.append(data[i:j])
        i = j
    i += 1  # single whitespace after maxval
    if len(tokens) < 4 or tokens[0] != b"P6":
        raise ValueError(f"{path}: not a P6 PPM")
    w, h, maxval = int(tokens[1]), int(tokens[2]), int(tokens[3])
    if maxval != 255:
        raise ValueError(f"{path}: maxval {maxval} != 255")
    px = data[i:i + w * h * 3]
    if len(px) < w * h * 3:
        raise ValueError(f"{path}: truncated pixel data")
    return w, h, bytearray(px)


def write_ppm(path, w, h, px):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode())
        f.write(px)


def luma_grid(px, w, h):
    """Per-pixel luma (0..255) as a flat list."""
    out = [0] * (w * h)
    for i in range(w * h):
        r, g, b = px[3 * i], px[3 * i + 1], px[3 * i + 2]
        out[i] = (r * 299 + g * 587 + b * 114) // 1000
    return out


def strong_edges(luma, w, h, edge_tol):
    """Boolean mask: pixel touches a strong luma gradient."""
    mask = bytearray(w * h)
    for y in range(h):
        row = y * w
        for x in range(w):
            i = row + x
            if x + 1 < w and abs(luma[i] - luma[i + 1]) > edge_tol:
                mask[i] = mask[i + 1] = 1
            if y + 1 < h and abs(luma[i] - luma[i + w]) > edge_tol:
                mask[i] = mask[i + w] = 1
    return mask


def dilate1(mask, w, h):
    """1px 8-connected dilation."""
    out = bytearray(mask)
    for y in range(h):
        row = y * w
        for x in range(w):
            if not mask[row + x]:
                continue
            for dy in (-1, 0, 1):
                ny = y + dy
                if ny < 0 or ny >= h:
                    continue
                for dx in (-1, 0, 1):
                    nx = x + dx
                    if 0 <= nx < w:
                        out[ny * w + nx] = 1
    return out


def diff_pair(ka, co, channel_tol, edge_tol):
    """Diff two (w, h, rgb) images. Returns a result dict + viz pixels."""
    kw, kh, kpx = ka
    cw, ch, cpx = co
    w, h = min(kw, cw), min(kh, ch)

    kl = luma_grid(kpx, kw, kh)
    cl = luma_grid(cpx, cw, ch)
    forgive = dilate1(
        _or_masks(strong_edges(kl, kw, kh, edge_tol),
                  strong_edges(cl, cw, ch, edge_tol), kw, kh),
        kw, kh) if (kw, kh) == (cw, ch) else None

    total = kw * kh
    mismatched = 0
    forgiven = 0
    viz = bytearray(kw * kh * 3)

    for y in range(kh):
        for x in range(kw):
            i = y * kw + x
            in_overlap = x < w and y < h
            delta = False
            if in_overlap:
                ki, ci = i * 3, (y * cw + x) * 3
                for c in range(3):
                    if abs(kpx[ki + c] - cpx[ci + c]) > channel_tol:
                        delta = True
                        break
            else:
                delta = True  # missing on the Compose side
            if delta:
                if forgive is not None and forgive[i]:
                    forgiven += 1
                    viz[i * 3:i * 3 + 3] = b"\xff\xc0\x00"  # amber
                else:
                    mismatched += 1
                    viz[i * 3:i * 3 + 3] = b"\xff\x00\x40"  # hot pink/red
            else:
                # Dimmed grey of the Klaxon pixel as context.
                v = kl[i] // 3 + 80
                viz[i * 3:i * 3 + 3] = bytes((v, v, v))

    return {
        "pixels": total,
        "mismatched": mismatched,
        "forgiven_edges": forgiven,
        "mismatch_pct": round(100.0 * mismatched / total, 4) if total else 0.0,
        "size_match": (kw, kh) == (cw, ch),
        "klaxon_size": [kw, kh],
        "compose_size": [cw, ch],
    }, viz


def _or_masks(a, b, w, h):
    out = bytearray(w * h)
    for i in range(w * h):
        out[i] = a[i] | b[i]
    return out


def html_report(report, path):
    rows = []
    for s in report["scenes"]:
        status = s.get("status", "ok")
        pct = s.get("mismatch_pct")
        pct_s = f"{pct:.2f}%" if pct is not None else "—"
        cls = "bad" if status != "ok" else ("warn" if pct and pct > 1.0 else "ok")
        diff = s.get("diff", "")
        diff_td = f'<a href="{os.path.relpath(diff, os.path.dirname(path))}">diff</a>' if diff else ""
        rows.append(
            f'<tr class="{cls}"><td>{s["id"]}</td><td>{s.get("widget","")}</td>'
            f'<td>{s.get("state","")}</td><td>{s.get("theme","")}</td>'
            f'<td>{s.get("dir","")}</td><td>{pct_s}</td>'
            f'<td>{s.get("mismatched","—")}</td><td>{s.get("forgiven_edges","—")}</td>'
            f"<td>{status}</td><td>{diff_td}</td></tr>")
    html = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>Klaxon × Compose fidelity report</title>
<style>
body {{ font: 13px/1.45 -apple-system, sans-serif; margin: 24px; }}
table {{ border-collapse: collapse; }}
td, th {{ border: 1px solid #ddd; padding: 3px 10px; text-align: left; }}
tr.warn td {{ background: #fff3d6; }} tr.bad td {{ background: #ffd9d9; }}
tr.ok td {{ background: #eaf7ea; }}
</style></head><body>
<h1>Klaxon × Compose pixel-fidelity report</h1>
<p>channel tolerance ±{report["channel_tol"]} · edge erosion 1px @ luma>{report["edge_tol"]}
 · {report["summary"]["ok"]}/{report["summary"]["total"]} compared
 · {report["summary"]["failed"]} failed/missing
 · mean mismatch {report["summary"]["mean_mismatch_pct"]:.3f}%
 · worst {report["summary"]["worst_scene"]} ({report["summary"]["worst_mismatch_pct"]:.2f}%)</p>
<table><tr><th>scene</th><th>widget</th><th>state</th><th>theme</th><th>dir</th>
<th>mismatch</th><th>px</th><th>forgiven</th><th>status</th><th></th></tr>
{''.join(rows)}
</table>
<p>Diff images: <b>red</b> = mismatch, <b>amber</b> = forgiven AA edge,
grey = match.</p>
</body></html>"""
    with open(path, "w") as f:
        f.write(html)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--klaxon-dir", default="fidelity/out/klaxon")
    ap.add_argument("--compose-dir", default="fidelity/out/compose")
    ap.add_argument("--diff-dir", default="fidelity/out/diff")
    ap.add_argument("--report-dir", default="fidelity")
    ap.add_argument("--channel-tol", type=int, default=DEFAULT_CHANNEL_TOL)
    ap.add_argument("--edge-tol", type=int, default=DEFAULT_EDGE_TOL)
    ap.add_argument("--scene", default=None)
    args = ap.parse_args()

    if not os.path.isdir(args.klaxon_dir):
        print(f"error: {args.klaxon_dir} missing — run `zig build fidelity` first", file=sys.stderr)
        return 2
    if not os.path.isdir(args.compose_dir):
        print(f"error: {args.compose_dir} missing — run fidelity/compose/run.sh first", file=sys.stderr)
        return 2

    klaxon_ids = {p[:-4] for p in os.listdir(args.klaxon_dir) if p.endswith(".ppm")}
    compose_ids = {p[:-4] for p in os.listdir(args.compose_dir) if p.endswith(".ppm")}
    all_ids = sorted(klaxon_ids | compose_ids)
    if args.scene:
        all_ids = [i for i in all_ids if args.scene in i]

    # Scene metadata (widget/state/theme/dir) from the Klaxon sidecar.
    meta = {}
    for sid in all_ids:
        mpath = os.path.join(args.klaxon_dir, f"{sid}.json")
        if os.path.exists(mpath):
            try:
                meta[sid] = json.load(open(mpath))
            except Exception:
                meta[sid] = {}

    scenes = []
    failures = 0
    for sid in all_ids:
        entry = {
            "id": sid,
            "widget": meta.get(sid, {}).get("widget", ""),
            "state": meta.get(sid, {}).get("state", ""),
            "theme": meta.get(sid, {}).get("theme", ""),
            "dir": meta.get(sid, {}).get("dir", ""),
        }
        kpath = os.path.join(args.klaxon_dir, f"{sid}.ppm")
        cpath = os.path.join(args.compose_dir, f"{sid}.ppm")
        if sid not in klaxon_ids:
            entry["status"] = "missing_klaxon"
            scenes.append(entry)
            failures += 1
            continue
        if sid not in compose_ids:
            entry["status"] = "missing_compose"
            scenes.append(entry)
            failures += 1
            continue
        try:
            ka = read_ppm(kpath)
            co = read_ppm(cpath)
        except Exception as e:
            entry["status"] = f"unreadable: {e}"
            scenes.append(entry)
            failures += 1
            continue

        stats, viz = diff_pair(ka, co, args.channel_tol, args.edge_tol)
        dpath = os.path.join(args.diff_dir, f"{sid}.ppm")
        write_ppm(dpath, stats["klaxon_size"][0], stats["klaxon_size"][1], viz)
        entry.update(stats)
        entry.update({
            "status": "ok",
            "klaxon": kpath,
            "compose": cpath,
            "diff": dpath,
        })
        scenes.append(entry)

    compared = [s for s in scenes if s.get("status") == "ok"]
    worst = max(compared, key=lambda s: s["mismatch_pct"], default=None)
    report = {
        "tool": "fidelity_diff.py",
        "channel_tol": args.channel_tol,
        "edge_tol": args.edge_tol,
        "summary": {
            "total": len(scenes),
            "ok": len(compared),
            "failed": failures,
            "mean_mismatch_pct": round(
                sum(s["mismatch_pct"] for s in compared) / len(compared), 4) if compared else 0.0,
            "worst_scene": worst["id"] if worst else "",
            "worst_mismatch_pct": worst["mismatch_pct"] if worst else 0.0,
        },
        "scenes": scenes,
    }

    os.makedirs(args.report_dir, exist_ok=True)
    rjson = os.path.join(args.report_dir, "report.json")
    rhtml = os.path.join(args.report_dir, "report.html")
    with open(rjson, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    html_report(report, rhtml)

    for s in scenes:
        if s.get("status") == "ok":
            print(f"{s['mismatch_pct']:7.3f}%  {s['id']}"
                  f"  ({s['mismatched']} px, {s['forgiven_edges']} forgiven)")
        else:
            print(f"  FAIL   {s['id']}: {s['status']}")
    print(f"\n{len(compared)}/{len(scenes)} compared · {failures} failed/missing"
          f" · mean {report['summary']['mean_mismatch_pct']:.3f}%"
          f" · worst {report['summary']['worst_scene']}"
          f" ({report['summary']['worst_mismatch_pct']:.2f}%)")
    print(f"-> {rjson}\n-> {rhtml}\n-> {args.diff_dir}/<id>.ppm")
    return 0 if failures == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
