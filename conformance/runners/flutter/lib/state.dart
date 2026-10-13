/// Port of `src/ui/state.zig` — Klaxon's fine-grained reactivity.
///
/// Semantics preserved 1:1 for the conformance corpus:
///   * `get()` inside a running [KxEffect] tracks a dependency.
///   * `peek()` reads without tracking.
///   * `set()` notifies subscribers only when the value actually changed.
///   * Subscribers run in subscription order over a *snapshot*; a subscriber
///     that unsubscribed mid-notify (or was added mid-notify) is skipped.
///   * [KxTextSignal] rejects writes over 1 MiB with 'TextTooLong'.
library;

/// Error whose [toString] mirrors the Zig `@errorName` — `action_error`
/// expectations compare against these names verbatim.
class KxError implements Exception {
  const KxError(this.name);
  final String name;
  @override
  String toString() => name;
}

/// Type-erased signal core: ordered subscriber list + version counter.
class KxSignalBase {
  final List<void Function()> _subs = [];
  int version = 0;

  /// Active effect — set while an effect body runs (global, like Klaxon's
  /// `current_effect`; the corpus never nests effects).
  static KxEffect? currentEffect;

  void subscribe(void Function() sub) => _subs.add(sub);

  void unsubscribe(void Function() sub) => _subs.remove(sub);

  void notify() {
    version += 1;
    // Iterate a snapshot: subscribers may (un)subscribe during notify.
    final snapshot = List<void Function()>.of(_subs);
    for (final sub in snapshot) {
      // Revalidate membership before firing (Klaxon does the same: a sub
      // destroyed by an earlier subscriber must not fire on a stale entry).
      if (_subs.contains(sub)) sub();
    }
  }
}

/// A reactive value of type [T] — `Signal(T)` in Klaxon.
class KxSignal<T> {
  KxSignal(this._value);
  final KxSignalBase base = KxSignalBase();
  T _value;

  /// Read the value; inside an effect run this tracks a dependency.
  T get() {
    KxSignalBase.currentEffect?.track(base);
    return _value;
  }

  /// Read without tracking.
  T peek() => _value;

  /// Set; no-op (no notifications) when unchanged.
  void set(T v) {
    if (_value == v) return;
    _value = v;
    base.notify();
  }

  /// Force-notify even when unchanged (`signal_notify` op, hot reload).
  void forceNotify() => base.notify();
}

/// A reactive, growable text channel — Klaxon's `TextSignal`.
/// Over-limit writes are rejected, never truncated.
class KxTextSignal {
  static const int maxLen = 1 << 20;

  KxTextSignal(String initial) : _value = initial {
    if (initial.length > maxLen) throw const KxError('TextTooLong');
  }

  final KxSignalBase base = KxSignalBase();
  String _value;

  String get() {
    KxSignalBase.currentEffect?.track(base);
    return _value;
  }

  String peek() => _value;

  void set(String v) {
    if (v.length > maxLen) throw const KxError('TextTooLong');
    if (_value == v) return;
    _value = v;
    base.notify();
  }

  void forceNotify() => base.notify();
}

/// Runs `fn`, re-running whenever a tracked dependency notifies.
class KxEffect {
  KxEffect(this._fn);
  final void Function() _fn;
  final List<KxSignalBase> _deps = [];

  void run() {
    for (final dep in _deps) {
      dep.unsubscribe(_onDep);
    }
    _deps.clear();
    final prev = KxSignalBase.currentEffect;
    KxSignalBase.currentEffect = this;
    try {
      _fn();
    } finally {
      KxSignalBase.currentEffect = prev;
    }
  }

  void track(KxSignalBase b) {
    if (_deps.contains(b)) return; // no duplicate subscriptions per run
    _deps.add(b);
    b.subscribe(_onDep);
  }

  void _onDep() => run();
}

/// Cached derived value — recomputes when its (tracked) dependencies change.
class KxMemo<T> {
  KxMemo(this._compute) {
    _effect = KxEffect(_recompute);
    _effect.run(); // initial compute (subscribes the deps it reads)
  }
  final T Function() _compute;
  final KxSignalBase base = KxSignalBase();
  late final KxEffect _effect;
  late T _cache;

  void _recompute() {
    _cache = _compute();
    base.notify();
  }

  /// Read the cached value; inside an effect this subscribes to the memo.
  T get() {
    KxSignalBase.currentEffect?.track(base);
    return _cache;
  }
}
