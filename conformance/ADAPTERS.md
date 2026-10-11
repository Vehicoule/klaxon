# Conformance Adapters — port contract

The corpus under `tests/` is framework-neutral: vectors describe a widget
tree, actions and expectations in terms of `SPEC.md` — nothing references
Klaxon internals. A **port** is a per-framework program that interprets the
same vectors and prints the same report, enabling honest cross-framework
comparison (the 4d.2 deliverable).

## What a port must implement

1. **Vector loading** — parse `tests/*.json` (format: `schema.json`).
2. **DSL → native mapping** — each `type` maps to the closest native
   construct (`column` → `Column`/`LinearLayout`/`QVBoxLayout`; `expanded`
   → `Expanded`/`flex`; `gesture_detector` → `GestureDetector`; ...). A
   port ships a `MAPPING.md` documenting each substitution.
3. **Deterministic globals** — virtual clock, seeded input router, a11y
   log bridge, locale tables as declared in `setup.locales`.
4. **Observability** — expose bounds, pixels, scroll offsets, focus,
   semantics, signal values and the widget event log with the same shapes
   as `expect` in `schema.json`.
5. **Report** — per-domain tallies + per-test pass/fail with
   human-readable mismatches (`expected X got Y`), plus a machine
   `results-<ts>.json` in the same shape Klaxon emits.

## Fidelity rules

- **Map, don't cheat**: if the framework has no equivalent primitive,
  implement the DSL type on top of what exists and document the
  approximation in `MAPPING.md` — never hand-write the expected output.
- **Same clock**: `tick` advances the framework's animation clock. No
  wall-clock sleeps.
- **Same tolerance**: default `0.01`, per-vector overridable. A stricter
  tolerance in a port is a bug, not a virtue.
- **Real pipeline**: pixels come from the framework's actual raster
  (offscreen surface), not from recomputed expectations.
- **No test special-casing**: the port must not branch on vector `id`s.
  Mapping quality issues surface as failures — that's the point.

## Reference

Klaxon's interpreter is `src/conformance.zig` (~1.7k LOC), driver
`src/conformance_main.zig` (`zig build conformance`). Reading those two
files is the fastest way to see what a port entails.

## Scoring equivalence

Two frameworks are comparable when they run the **same vectors** with the
**same tolerance** and report the same per-domain shape. Differences in
adapter quality are themselves data — a framework that can't express a
rule scores 0 on it and says why.
