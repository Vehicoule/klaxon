/// Port of `src/ui/navigator.zig` — the model-level Navigator (stack of
/// pages, pattern routes, `{param}` captures, query params, deep links,
/// transitions are recorded but the corpus never animates them).
///
/// Error names match the Zig `@errorName` strings (`action_error` vectors).
library;

import 'state.dart';

const int maxParams = 8;

enum KxTransition { none, slide, slide_up, fade, scale }

enum KxNavChange { push, pop, replace, reset }

class KxParams {
  final List<MapEntry<String, String>> items = [];

  String? get(String key) {
    for (final it in items) {
      if (it.key == key) return it.value;
    }
    return null;
  }

  bool add(String key, String value) {
    if (items.length >= maxParams) return false;
    items.add(MapEntry(key, value));
    return true;
  }
}

class KxRoute {
  KxRoute({required this.pattern, required this.path, required this.params, this.transition = KxTransition.slide});
  final String pattern;
  final String path;
  final KxParams params;
  final KxTransition transition;
}

class KxPage {
  KxPage({required this.id, required this.route});
  final int id;
  final KxRoute route;
}

class KxRouteDef {
  KxRouteDef(this.pattern, this.transition);
  final String pattern;
  final KxTransition transition;
}

class KxNavigator {
  final List<KxPage> pages = [];
  final List<KxRouteDef> routes = [];
  void Function(KxNavChange kind)? onChange;
  int _nextId = 1;

  int get depth => pages.length;
  bool get canPop => pages.length > 1;
  KxPage? get current => pages.isEmpty ? null : pages.last;

  void define(String pattern, KxTransition transition) {
    routes.add(KxRouteDef(pattern, transition));
  }

  /// Push a route by pattern ("anime/{id}" + params → "anime/42").
  void push(String pattern, KxParams params) {
    final def = _findDef(pattern);
    if (def == null) throw const KxError('UnknownRoute');
    final path = buildPath(pattern, params);
    _pushDef(def, path, params);
  }

  /// Push a concrete path: match a pattern, merge explicit params after
  /// the path captures.
  void pushPath(String path, KxParams params) {
    final matched = KxParams();
    KxRouteDef? def;
    for (final r in routes) {
      if (matchPattern(r.pattern, path, matched)) {
        def = r;
        break;
      }
      matched.items.clear();
    }
    if (def == null) throw const KxError('UnknownRoute');
    for (final p in params.items) {
      if (!matched.add(p.key, p.value)) throw const KxError('TooManyParams');
    }
    _pushDef(def, path, matched);
  }

  /// Deep link "klaxon://anime/42?tab=2" (scheme optional). Navigating to
  /// the route already on top is a no-op.
  void navigateTo(String uri) {
    final parsed = parseUri(uri);
    if (parsed == null) throw const KxError('InvalidUri');
    final params = KxParams();
    KxRouteDef? def;
    for (final r in routes) {
      params.items.clear();
      if (matchPattern(r.pattern, parsed.$1, params)) {
        def = r;
        break;
      }
    }
    if (def == null) throw const KxError('UnknownRoute');
    var q = parsed.$2;
    while (q.isNotEmpty) {
      final amp = q.indexOf('&');
      final pair = amp >= 0 ? q.substring(0, amp) : q;
      q = amp >= 0 ? q.substring(amp + 1) : '';
      final eq = pair.indexOf('=');
      if (eq < 0) throw const KxError('InvalidUri');
      if (!params.add(pair.substring(0, eq), pair.substring(eq + 1))) {
        throw const KxError('TooManyParams');
      }
    }
    final top = current;
    if (top != null && top.route.path == parsed.$1) return;
    _pushDef(def, parsed.$1, params);
  }

  /// Back: pop while deeper than the root. False at the root.
  bool onBack() => pop();

  /// Pop the top page. False at the root (the stack never empties).
  bool pop() {
    if (!canPop) return false;
    pages.removeLast();
    _notify(KxNavChange.pop);
    return true;
  }

  /// Replace the top page (same depth). On an empty stack this is a push.
  void replace(String pattern, KxParams params) {
    if (pages.isEmpty) return push(pattern, params);
    final def = _findDef(pattern);
    if (def == null) throw const KxError('UnknownRoute');
    final path = buildPath(pattern, params);
    pages.removeLast();
    pages.add(KxPage(id: _nextId++, route: KxRoute(pattern: def.pattern, path: path, params: params, transition: def.transition)));
    _notify(KxNavChange.replace);
  }

  /// Pop everything above the root.
  void popToRoot() {
    if (pages.length <= 1) return;
    pages.removeRange(1, pages.length);
    _notify(KxNavChange.reset);
  }

  KxRouteDef? _findDef(String pattern) {
    for (final r in routes) {
      if (r.pattern == pattern) return r;
    }
    return null;
  }

  void _pushDef(KxRouteDef def, String path, KxParams params) {
    if (params.items.length > maxParams) throw const KxError('TooManyParams');
    final owned = KxParams()..items.addAll(params.items);
    pages.add(KxPage(id: _nextId++, route: KxRoute(pattern: def.pattern, path: path, params: owned, transition: def.transition)));
    _notify(KxNavChange.push);
  }

  void _notify(KxNavChange kind) => onChange?.call(kind);
}

/// Build the concrete path from a pattern + params ("anime/{id}" + id=42).
String buildPath(String pattern, KxParams params) {
  final buf = StringBuffer();
  var first = true;
  for (final seg in pattern.split('/')) {
    if (!first) buf.write('/');
    first = false;
    if (seg.length >= 2 && seg.startsWith('{') && seg.endsWith('}')) {
      final key = seg.substring(1, seg.length - 1);
      final v = params.get(key);
      if (v == null) throw const KxError('MissingParam');
      buf.write(v);
    } else {
      buf.write(seg);
    }
  }
  return buf.toString();
}

/// Match a path against a pattern; "{name}" segments capture into `params`.
/// Static segments must be equal; the arity must match.
bool matchPattern(String pattern, String path, KxParams params) {
  params.items.clear();
  final pit = pattern.split('/');
  final hit = path.split('/');
  if (pit.length != hit.length) return false;
  for (var i = 0; i < pit.length; i++) {
    final p = pit[i];
    final h = hit[i];
    if (p.length >= 2 && p.startsWith('{') && p.endsWith('}')) {
      if (!params.add(p.substring(1, p.length - 1), h)) return false;
    } else if (p != h) {
      return false;
    }
  }
  return true;
}

/// Parse "scheme://path?query" (scheme optional). Trailing slash stripped.
(String path, String query)? parseUri(String uri) {
  var rest = uri;
  final i = rest.indexOf('://');
  if (i >= 0) rest = rest.substring(i + 3);
  var path = rest;
  var query = '';
  final q = rest.indexOf('?');
  if (q >= 0) {
    path = rest.substring(0, q);
    query = rest.substring(q + 1);
  }
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.isEmpty) return null;
  return (path, query);
}
