/// Faithful port of `src/ui/gestures.zig` — the Klaxon gesture arena.
///
/// Flutter's stock recognizers cannot express this contract (pan claims at
/// 12px vs `kPanSlop`=36, a 200ms tap timeout vs `kPressTimeout`=100ms-only-
/// when-contended, timer-exact long press, dual-fire pinch+rotate), so the
/// adapter feeds raw `Listener` events into a line-for-line port of the
/// Klaxon state machines. See MAPPING.md §gestures.
library;

import 'dart:math' as math;

enum KxGKind { tap, doubleTap, longPress, pan, swipe, pinch, rotate }

enum KxRecState { idle, possible, accepted, rejected }

const double kSlop = 12; // movement tolerance before a gesture claims
const int kTapTimeoutMs = 200; // max duration of a tap
const int kDoubleTapMs = 300; // max interval between two taps
const int kLongPressMs = 500; // hold duration for a long-press
const double kSwipeVelocity = 500; // px/s fling threshold
const int kVelocityWindowMs = 100; // velocity estimation window

double _dist(double x1, double y1, double x2, double y2) {
  final dx = x2 - x1, dy = y2 - y1;
  return math.sqrt(dx * dx + dy * dy);
}

/// A raw pointer sample in the window/coordinate space + virtual clock ms.
class KxPEvent {
  KxPEvent(this.phase, this.x, this.y, this.t, this.pointer);
  final String phase; // 'down' | 'move' | 'up' | 'cancel' | 'enter' | 'leave'
  final double x, y;
  final int t;
  final int pointer;
}

/// One fired gesture — the names are what `expect.gestures` compares.
class KxFire {
  KxFire(this.name);
  final String name; // tap | double_tap | long_press | pan_start | pan_update | pan_end | swipe:<dir> | pinch | rotate
}

class _Sample {
  _Sample(this.x, this.y, this.t);
  double x, y;
  int t;
}

class _TrackedPtr {
  _TrackedPtr(this.id, this.x, this.y);
  int id;
  double x, y;
}

/// A single Klaxon recognizer (tap/double_tap/long_press/pan/swipe/pinch/
/// rotate) — same fields as Zig `Recognizer`.
class KxRecognizer {
  KxRecognizer(this.kind);
  final KxGKind kind;
  KxRecState state = KxRecState.idle;

  int? tracking; // single-pointer owner
  double startX = 0, startY = 0;
  int startTime = 0;
  double lastX = 0, lastY = 0;
  final List<_Sample> samples = [];

  // double-tap memory survives cancels
  bool hasLastTap = false;
  int lastTapTime = 0;
  double lastTapX = 0, lastTapY = 0;

  // two-pointer state
  _TrackedPtr? ptrA, ptrB;
  double initialDistance = 0, initialAngle = 0, lastAngle = 0;
  bool longPressFired = false;

  void reset() {
    state = KxRecState.idle;
    tracking = null;
    ptrA = null;
    ptrB = null;
    longPressFired = false;
    samples.clear();
    // double-tap memory is not gesture state: it survives cancels.
  }

  bool follows(KxPEvent ev) {
    final p = tracking;
    if (p != null) return ev.pointer == p;
    return ev.phase == 'down';
  }

  void beginDown(KxPEvent ev) {
    state = KxRecState.possible;
    tracking = ev.pointer;
    startX = ev.x;
    startY = ev.y;
    startTime = ev.t;
    lastX = ev.x;
    lastY = ev.y;
  }

  void addSample(KxPEvent ev) {
    if (samples.length == 8) {
      samples.removeAt(0);
    }
    samples.add(_Sample(ev.x, ev.y, ev.t));
  }

  ({double vx, double vy}) velocity(int now) {
    if (samples.isEmpty) return (vx: 0, vy: 0);
    var first = samples.last;
    for (final s in samples) {
      if (now - s.t <= kVelocityWindowMs) {
        first = s;
        break;
      }
    }
    final last = samples.last;
    final dtMs = last.t - first.t;
    if (dtMs == 0) return (vx: 0, vy: 0);
    final dt = dtMs / 1000.0;
    return (vx: (last.x - first.x) / dt, vy: (last.y - first.y) / dt);
  }

  void trackDown(KxPEvent ev) {
    if (ptrA == null) {
      ptrA = _TrackedPtr(ev.pointer, ev.x, ev.y);
    } else if (ptrB == null && ev.pointer != ptrA!.id) {
      ptrB = _TrackedPtr(ev.pointer, ev.x, ev.y);
    }
    if (ptrA != null && ptrB != null) {
      initialDistance = _dist(ptrA!.x, ptrA!.y, ptrB!.x, ptrB!.y);
      initialAngle = math.atan2(ptrB!.y - ptrA!.y, ptrB!.x - ptrA!.x);
      lastAngle = initialAngle;
      state = KxRecState.accepted;
    }
  }

  bool trackUp(KxPEvent ev) {
    var lifted = false;
    if (ptrA?.id == ev.pointer) {
      ptrA = null;
      lifted = true;
    }
    if (ptrB?.id == ev.pointer) {
      ptrB = null;
      lifted = true;
    }
    if (lifted) state = KxRecState.idle;
    return lifted;
  }

  bool trackMove(KxPEvent ev) {
    if (ptrA?.id == ev.pointer) {
      ptrA!.x = ev.x;
      ptrA!.y = ev.y;
      return true;
    }
    if (ptrB?.id == ev.pointer) {
      ptrB!.x = ev.x;
      ptrB!.y = ev.y;
      return true;
    }
    return false;
  }

  /// `Recognizer.feed` — one event in, at most one fire out.
  KxFire? feed(KxPEvent ev) {
    switch (kind) {
      case KxGKind.tap:
        return _feedTap(ev);
      case KxGKind.doubleTap:
        return _feedDoubleTap(ev);
      case KxGKind.longPress:
        return _feedLongPress(ev);
      case KxGKind.pan:
      case KxGKind.swipe:
        return _feedPan(ev);
      case KxGKind.pinch:
        return _feedPinch(ev);
      case KxGKind.rotate:
        return _feedRotate(ev);
    }
  }

  KxFire? _feedTap(KxPEvent ev) {
    if (!follows(ev)) return null;
    switch (ev.phase) {
      case 'down':
        beginDown(ev);
        return null;
      case 'move':
        if (state == KxRecState.possible &&
            _dist(ev.x, ev.y, startX, startY) > kSlop) {
          state = KxRecState.rejected;
        }
        lastX = ev.x;
        lastY = ev.y;
        return null;
      case 'up':
        final ok = state == KxRecState.possible &&
            _dist(ev.x, ev.y, startX, startY) <= kSlop &&
            ev.t - startTime < kTapTimeoutMs;
        state = KxRecState.idle;
        tracking = null;
        return ok ? KxFire('tap') : null;
      default:
        reset();
        return null;
    }
  }

  KxFire? _feedDoubleTap(KxPEvent ev) {
    if (!follows(ev)) return null;
    switch (ev.phase) {
      case 'down':
        beginDown(ev);
        return null;
      case 'move':
        if (state == KxRecState.possible &&
            _dist(ev.x, ev.y, startX, startY) > kSlop) {
          state = KxRecState.rejected;
        }
        return null;
      case 'up':
        final isTap = state == KxRecState.possible &&
            _dist(ev.x, ev.y, startX, startY) <= kSlop &&
            ev.t - startTime < kTapTimeoutMs;
        state = KxRecState.idle;
        tracking = null;
        if (!isTap) {
          hasLastTap = false;
          return null;
        }
        if (hasLastTap &&
            ev.t - lastTapTime < kDoubleTapMs &&
            _dist(ev.x, ev.y, lastTapX, lastTapY) <= kSlop) {
          hasLastTap = false;
          return KxFire('double_tap');
        }
        lastTapTime = ev.t;
        lastTapX = ev.x;
        lastTapY = ev.y;
        hasLastTap = true;
        return null;
      default:
        reset();
        return null;
    }
  }

  KxFire? _feedLongPress(KxPEvent ev) {
    if (!follows(ev)) return null;
    switch (ev.phase) {
      case 'down':
        beginDown(ev);
        longPressFired = false;
        return null;
      case 'move':
        if (state != KxRecState.possible) return null;
        if (_dist(ev.x, ev.y, startX, startY) > kSlop) {
          state = KxRecState.rejected;
          return null;
        }
        if (!longPressFired && ev.t - startTime >= kLongPressMs) {
          longPressFired = true;
          state = KxRecState.idle;
          tracking = null;
          return KxFire('long_press');
        }
        return null;
      case 'up':
        final ok = state == KxRecState.possible &&
            !longPressFired &&
            _dist(ev.x, ev.y, startX, startY) <= kSlop &&
            ev.t - startTime >= kLongPressMs;
        state = KxRecState.idle;
        tracking = null;
        return ok ? KxFire('long_press') : null;
      default:
        reset();
        return null;
    }
  }

  KxFire? _feedPan(KxPEvent ev) {
    if (!follows(ev)) return null;
    switch (ev.phase) {
      case 'down':
        beginDown(ev);
        samples.clear();
        addSample(ev);
        return null;
      case 'move':
        if (state == KxRecState.possible) {
          if (_dist(ev.x, ev.y, startX, startY) > kSlop) {
            state = KxRecState.accepted;
            lastX = ev.x; // the claiming move is the delta origin
            lastY = ev.y;
            addSample(ev);
            return KxFire('pan_start');
          }
          return null;
        }
        if (state == KxRecState.accepted) {
          lastX = ev.x;
          lastY = ev.y;
          addSample(ev);
          return KxFire('pan_update');
        }
        return null;
      case 'up':
        if (state != KxRecState.accepted) {
          state = KxRecState.idle;
          tracking = null;
          return null;
        }
        state = KxRecState.idle;
        tracking = null;
        addSample(ev);
        final v = velocity(ev.t);
        if (kind == KxGKind.swipe &&
            math.max(v.vx.abs(), v.vy.abs()) > kSwipeVelocity) {
          final dir = v.vx.abs() >= v.vy.abs()
              ? (v.vx > 0 ? 'right' : 'left')
              : (v.vy > 0 ? 'down' : 'up');
          return KxFire('swipe:$dir');
        }
        return KxFire('pan_end');
      default:
        reset();
        return null;
    }
  }

  KxFire? _feedPinch(KxPEvent ev) {
    switch (ev.phase) {
      case 'down':
        trackDown(ev);
        return null;
      case 'move':
        if (state != KxRecState.accepted || !trackMove(ev)) return null;
        if (initialDistance <= 0) return null;
        return KxFire('pinch'); // scale = dist(a,b)/initialDistance (unused)
      case 'up':
        trackUp(ev);
        return null;
      default:
        reset();
        return null;
    }
  }

  KxFire? _feedRotate(KxPEvent ev) {
    switch (ev.phase) {
      case 'down':
        trackDown(ev);
        return null;
      case 'move':
        if (state != KxRecState.accepted || !trackMove(ev)) return null;
        final a = ptrA!, b = ptrB!;
        final angle = math.atan2(b.y - a.y, b.x - a.x);
        var d = angle - lastAngle;
        while (d > math.pi) {
          d -= 2 * math.pi;
        }
        while (d < -math.pi) {
          d += 2 * math.pi;
        }
        lastAngle = angle;
        return KxFire('rotate');
      case 'up':
        trackUp(ev);
        return null;
      default:
        reset();
        return null;
    }
  }

  /// `Recognizer.tick` — fires time-based gestures at the threshold.
  KxFire? tick(int nowMs) {
    if (kind != KxGKind.longPress) return null;
    if (state != KxRecState.possible || longPressFired) return null;
    if (nowMs - startTime < kLongPressMs) return null;
    longPressFired = true;
    state = KxRecState.idle;
    tracking = null;
    return KxFire('long_press');
  }
}

/// `GestureArena` — recognizers compete in DSL-declared order; the first to
/// claim wins. Two-pointer gestures are fed first and co-fire; when one
/// accepts it claims the interaction (single-pointer recognizers reset).
/// Terminal gestures resolve after the pass: double_tap suppresses the
/// same-event tap.
class KxGestureArena {
  KxGestureArena(Set<String> enabled, void Function(String name) onFire)
      : _enabled = enabled, _onFire = onFire {
    void add(KxGKind k, bool e) {
      if (e) recognizers.add(KxRecognizer(k));
    }

    add(KxGKind.tap, enabled.contains('tap'));
    add(KxGKind.doubleTap, enabled.contains('double_tap'));
    add(KxGKind.longPress, enabled.contains('long_press'));
    add(
      KxGKind.pan,
      enabled.contains('pan_start') ||
          enabled.contains('pan_update') ||
          enabled.contains('pan_end'),
    );
    add(KxGKind.swipe, enabled.contains('swipe'));
    add(KxGKind.pinch, enabled.contains('pinch'));
    add(KxGKind.rotate, enabled.contains('rotate'));
  }

  final Set<String> _enabled;
  final List<KxRecognizer> recognizers = [];
  final void Function(String) _onFire;

  /// Klaxon dispatches each recognizer event to *its* callback slot — a
  /// swipe recognizer's internal pan_start/pan_end are dropped unless the
  /// detector also enabled those names.
  void _emit(String name) {
    final key = name.startsWith('swipe:') ? 'swipe' : name;
    if (_enabled.contains(key)) _onFire(name);
  }

  void feed(KxPEvent ev) {
    if (ev.phase == 'enter' || ev.phase == 'leave' || ev.phase == 'outside_down') {
      cancel();
      return;
    }
    var twoFingerActive = false;
    for (final r in recognizers) {
      if (r.kind != KxGKind.pinch && r.kind != KxGKind.rotate) continue;
      final f = r.feed(ev);
      if (f != null) _emit(f.name);
      if (r.state == KxRecState.accepted) {
        twoFingerActive = true;
        for (final o in recognizers) {
          if (o.kind == KxGKind.pinch || o.kind == KxGKind.rotate) continue;
          o.reset();
        }
      }
    }
    if (twoFingerActive) return;

    var tapFire = false, doubleTapFire = false;
    KxFire? terminal;
    for (final r in recognizers) {
      if (r.kind == KxGKind.pinch || r.kind == KxGKind.rotate) continue;
      final f = r.feed(ev);
      if (f == null) continue;
      switch (f.name) {
        case 'tap':
          tapFire = true;
        case 'double_tap':
          doubleTapFire = true;
        case 'pan_start' || 'pan_update':
          _emit(f.name);
        case 'long_press' || 'pan_end' || _:
          if (f.name.startsWith('swipe:') ||
              f.name == 'long_press' ||
              f.name == 'pan_end') {
            terminal ??= f;
          }
      }
    }
    if (doubleTapFire) {
      _emit('double_tap');
    } else if (tapFire) {
      _emit('tap');
    } else if (terminal != null) {
      _emit(terminal.name);
    }
  }

  void cancel() {
    for (final r in recognizers) {
      r.reset();
    }
  }

  void tick(int nowMs) {
    for (final r in recognizers) {
      final f = r.tick(nowMs);
      if (f != null) _emit(f.name);
    }
  }
}
