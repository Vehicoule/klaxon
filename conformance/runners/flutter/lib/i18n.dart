/// Port of `src/ui/i18n.zig` — locales, ARB messages, `{name}` interpolation,
/// ARB plural blocks + built-in CLDR rules (en/fr/ja/ar), per-locale
/// number/date formatting tables, and the global text direction.
///
/// Deliberately framework-free: the corpus exercises Klaxon's own formatting
/// (not ICU/`intl`), so this adapter ports the same tables instead of
/// pulling in Flutter's `intl` — the expectation strings are Klaxon's.
library;

import 'state.dart';

enum KxDir { ltr, rtl }

enum KxPluralCat { zero, one, two, few, many, other }

enum KxDateKind { short, medium, long }

class KxNumberOpts {
  int? decimals;
  bool percent = false;
  bool grouping = true;
}

class KxLocale {
  KxLocale(this.tag);

  final String tag;
  KxDir direction = KxDir.ltr;
  final Map<String, String> messages = {};

  // Number formatting.
  String decimalSep = '.';
  String groupSep = ',';

  // Date formatting (pattern tokens y/M/d, repeats set width).
  String dateShort = 'M/d/yy';
  String dateMedium = 'MMM d, y';
  String dateLong = 'MMMM d, y';
  List<String> monthLong = const [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];
  List<String> monthShort = const [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep',
    'Oct', 'Nov', 'Dec',
  ];

  /// ARB: keys starting with '@' are metadata and skipped.
  void loadArb(Map<String, dynamic> doc) {
    for (final e in doc.entries) {
      if (e.key.isEmpty || e.key.startsWith('@')) continue;
      final v = e.value;
      if (v is String) messages[e.key] = v;
    }
  }

  /// Format a number per the locale (grouping, separators, percent).
  /// Digits come from the shortest round-trip representation, like Zig's {d}.
  String formatNumber(double value, KxNumberOpts opts) {
    final buf = StringBuffer();
    var v = value;
    if (v < 0) {
      buf.write('-');
      v = -v;
    }
    if (opts.percent) v *= 100;
    // Shortest round-trip digits, then split integer/fraction.
    final all = (v == v.truncateToDouble() && v.abs() < 1e21)
        ? v.toInt().toString()
        : v.toString();
    var intPart = all;
    var fracPart = '';
    final dot = all.indexOf('.');
    if (dot >= 0) {
      intPart = all.substring(0, dot);
      fracPart = all.substring(dot + 1);
    }
    // Group the integer part (groups of 3, from the right).
    if (opts.grouping && intPart.length > 3) {
      final len = intPart.length;
      final rem = len % 3;
      final firstN = rem == 0 ? 3 : rem;
      buf.write(intPart.substring(0, firstN));
      var pos = firstN;
      while (pos < len) {
        buf.write(groupSep);
        buf.write(intPart.substring(pos, pos + 3));
        pos += 3;
      }
    } else {
      buf.write(intPart);
    }
    if (opts.decimals != null) {
      final d = opts.decimals!;
      if (d > 0) {
        buf.write(decimalSep);
        for (var i = 0; i < d; i++) {
          buf.write(i < fracPart.length ? fracPart[i] : '0');
        }
      }
    } else if (fracPart.isNotEmpty) {
      buf.write(decimalSep);
      buf.write(fracPart);
    }
    if (opts.percent) buf.write('%');
    return buf.toString();
  }

  /// Format a date per the locale and kind (pattern tokens y/M/d).
  String formatDate(int year, int month, int day, KxDateKind kind) {
    final pattern = switch (kind) {
      KxDateKind.short => dateShort,
      KxDateKind.medium => dateMedium,
      KxDateKind.long => dateLong,
    };
    final buf = StringBuffer();
    var i = 0;
    while (i < pattern.length) {
      final ch = pattern[i];
      if (ch != 'y' && ch != 'M' && ch != 'd') {
        buf.write(ch);
        i += 1;
        continue;
      }
      var j = i;
      while (j < pattern.length && pattern[j] == ch) {
        j += 1;
      }
      final n = j - i;
      switch (ch) {
        case 'y':
          if (n == 2) {
            buf.write((year % 100).abs().toString().padLeft(2, '0'));
          } else {
            buf.write(year.toString());
          }
        case 'M':
          final m = month - 1;
          switch (n) {
            case 1:
              buf.write(month.toString());
            case 2:
              buf.write(month.toString().padLeft(2, '0'));
            case 3:
              buf.write(monthShort[m]);
            default:
              buf.write(monthLong[m]);
          }
        case 'd':
          buf.write(n >= 2 ? day.toString().padLeft(2, '0') : day.toString());
      }
      i = j;
    }
    return buf.toString();
  }
}

/// Built-in per-locale format data (en/fr/ja/ar; others keep en defaults).
void applyFormatData(KxLocale loc) {
  final base = loc.tag.contains('-') ? loc.tag.split('-').first : loc.tag;
  switch (base) {
    case 'fr':
      loc.decimalSep = ',';
      loc.groupSep = ' ';
      loc.dateShort = 'dd/MM/y';
      loc.dateMedium = 'd MMM y';
      loc.dateLong = 'd MMMM y';
      loc.monthLong = const [
        'janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet',
        'août', 'septembre', 'octobre', 'novembre', 'décembre',
      ];
      loc.monthShort = const [
        'janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août',
        'sept.', 'oct.', 'nov.', 'déc.',
      ];
    case 'ja':
      loc.dateShort = 'y/MM/dd';
      loc.dateMedium = 'y/MM/dd';
      loc.dateLong = 'y年M月d日';
      loc.monthLong = const [
        '1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月',
        '10月', '11月', '12月',
      ];
      loc.monthShort = const [
        '1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月',
        '10月', '11月', '12月',
      ];
    case 'ar':
      loc.direction = KxDir.rtl;
      loc.dateShort = 'd/M/y';
      loc.dateMedium = 'd MMM y';
      loc.dateLong = 'd MMMM y';
      loc.monthLong = const [
        'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو',
        'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
      ];
      loc.monthShort = const [
        'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو',
        'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر',
      ];
  }
}

/// CLDR plural category for a locale tag and count (en/fr/ja/ar built in).
KxPluralCat pluralCategory(String tag, int n) {
  final base = tag.contains('-') ? tag.split('-').first : tag;
  switch (base) {
    case 'fr':
      return (n >= 0 && n < 2) ? KxPluralCat.one : KxPluralCat.other;
    case 'ja':
      return KxPluralCat.other;
    case 'ar':
      if (n == 0) return KxPluralCat.zero;
      if (n == 1) return KxPluralCat.one;
      if (n == 2) return KxPluralCat.two;
      if (n > 0) {
        final m100 = n % 100;
        if (m100 >= 3 && m100 <= 10) return KxPluralCat.few;
        if (m100 >= 11 && m100 <= 99) return KxPluralCat.many;
      }
      return KxPluralCat.other;
    default:
      return n == 1 ? KxPluralCat.one : KxPluralCat.other;
  }
}

class KxPluralBranch {
  int? exact; // `=N` selector
  KxPluralCat? category;
  String text = '';
}

class KxPluralMsg {
  final List<KxPluralBranch> branches = [];
  String prefix = ''; // text before the block's '{'
  String suffix = ''; // text after the block's '}'
}

const _pluralCatNames = {
  'zero': KxPluralCat.zero,
  'one': KxPluralCat.one,
  'two': KxPluralCat.two,
  'few': KxPluralCat.few,
  'many': KxPluralCat.many,
  'other': KxPluralCat.other,
};

/// Parse an ARB plural block: `{count, plural, =0 {...} one {...} other {...}}`.
KxPluralMsg? parsePlural(String msg) {
  final p = msg.indexOf(', plural,');
  if (p < 0) return null;
  final open = msg.lastIndexOf('{', p - 1);
  if (open < 0) return null;
  final out = KxPluralMsg()..prefix = msg.substring(0, open);
  var i = p + ', plural,'.length;
  while (i < msg.length) {
    while (i < msg.length && msg[i] == ' ') {
      i += 1;
    }
    if (i >= msg.length) return null;
    if (msg[i] == '}') {
      out.suffix = msg.substring(i + 1);
      return out.branches.isNotEmpty ? out : null;
    }
    final branch = KxPluralBranch();
    if (msg[i] == '=') {
      i += 1;
      var num = 0;
      var neg = false;
      if (i < msg.length && msg[i] == '-') {
        neg = true;
        i += 1;
      }
      while (i < msg.length && msg.codeUnitAt(i) >= 0x30 && msg.codeUnitAt(i) <= 0x39) {
        num = num * 10 + (msg.codeUnitAt(i) - 0x30);
        i += 1;
      }
      branch.exact = neg ? -num : num;
    } else {
      final start = i;
      while (i < msg.length && msg[i] != ' ' && msg[i] != '{') {
        i += 1;
      }
      branch.category = _pluralCatNames[msg.substring(start, i)];
    }
    while (i < msg.length && msg[i] == ' ') {
      i += 1;
    }
    if (i >= msg.length || msg[i] != '{') return null;
    i += 1;
    final textStart = i;
    var depth = 1;
    while (i < msg.length && depth > 0) {
      if (msg[i] == '{') depth += 1;
      if (msg[i] == '}') depth -= 1;
      i += 1;
    }
    if (depth != 0) return null;
    branch.text = msg.substring(textStart, i - 1);
    if (out.branches.length >= 16) return null;
    out.branches.add(branch);
  }
  return out.branches.isNotEmpty ? out : null;
}

/// Select the branch for a count: exact `=N` first, then the CLDR category,
/// then `other`.
String? selectPlural(KxPluralMsg msg, String tag, int count) {
  for (final b in msg.branches) {
    if (b.exact != null && b.exact == count) return b.text;
  }
  final cat = pluralCategory(tag, count);
  for (final b in msg.branches) {
    if (b.category != null && b.category == cat) return b.text;
  }
  for (final b in msg.branches) {
    if (b.category == KxPluralCat.other) return b.text;
  }
  return null;
}

/// Interpolate `{name}` placeholders; unknown placeholders stay as-is.
String interpolate(String msg, Map<String, Object> args) {
  final buf = StringBuffer();
  var i = 0;
  while (i < msg.length) {
    if (msg[i] == '{') {
      final close = msg.indexOf('}', i);
      if (close >= 0) {
        final name = msg.substring(i + 1, close);
        final v = args[name];
        if (v != null) {
          buf.write('$v');
          i = close + 1;
          continue;
        }
      }
    }
    buf.write(msg[i]);
    i += 1;
  }
  return buf.toString();
}

/// Interpolate a plural branch: `#` and `{count}` expand to the count.
String interpolatePlural(String branch, int count, Map<String, Object> args) {
  final buf = StringBuffer();
  final countStr = count.toString();
  var i = 0;
  while (i < branch.length) {
    if (branch[i] == '#') {
      buf.write(countStr);
      i += 1;
      continue;
    }
    if (branch[i] == '{') {
      final close = branch.indexOf('}', i);
      if (close >= 0) {
        final name = branch.substring(i + 1, close);
        if (name == 'count') {
          buf.write(countStr);
          i = close + 1;
          continue;
        }
        final v = args[name];
        if (v != null) {
          buf.write('$v');
          i = close + 1;
          continue;
        }
      }
    }
    buf.write(branch[i]);
    i += 1;
  }
  return buf.toString();
}

/// The locale registry + current locale (Klaxon's `I18n`).
class KxI18n {
  KxI18n(this.fallback);

  final String fallback;
  final Map<String, KxLocale> locales = {};
  KxLocale? current;

  /// Locale-switch signal — localized widgets subscribe and re-render.
  final KxSignal<String> localeSig = KxSignal('');

  /// Register/replace a locale from an ARB document.
  void addArb(String tag, Map<String, dynamic> arb, KxDir dir) {
    final replacingCurrent = current?.tag == tag;
    final oldDir = replacingCurrent ? current!.direction : null;
    final loc = locales.putIfAbsent(tag, () => KxLocale(tag));
    loc.messages.clear();
    loc.direction = dir;
    loc.loadArb(arb);
    applyFormatData(loc);
    if (replacingCurrent) current = loc;
    current ??= loc;
    if (oldDir != null) {
      localeSig.forceNotify();
      if (loc.direction != oldDir) onDirectionChanged?.call();
    } else if (tag == fallback) {
      localeSig.forceNotify();
    }
  }

  /// Fired when a locale switch/reload flips the text direction.
  void Function()? onDirectionChanged;

  /// Switch the active locale; unknown tags throw 'UnknownLocale'.
  void setLocale(String tag) {
    final loc = locales[tag];
    if (loc == null) throw const KxError('UnknownLocale');
    final oldDir = direction;
    current = loc;
    localeSig.set(loc.tag);
    if (direction != oldDir) onDirectionChanged?.call();
  }

  KxDir get direction => current?.direction ?? KxDir.ltr;

  /// Resolve: current locale → fallback locale → the key itself.
  String tr(String key) {
    final cur = current;
    if (cur != null) {
      final m = cur.messages[key];
      if (m != null) return m;
    }
    final fb = locales[fallback];
    if (fb != null) {
      final m = fb.messages[key];
      if (m != null) return m;
    }
    return key;
  }

  /// Resolve + interpolate `{name}` placeholders.
  String trArgs(String key, Map<String, Object> args) =>
      interpolate(tr(key), args);

  /// Resolve a message + the tag of the locale that provided it (plural
  /// rules follow the message's locale, not the active one).
  (String, String) trTagged(String key) {
    final cur = current;
    if (cur != null) {
      final m = cur.messages[key];
      if (m != null) return (m, cur.tag);
    }
    final fb = locales[fallback];
    if (fb != null) {
      final m = fb.messages[key];
      if (m != null) return (m, fb.tag);
    }
    return (key, cur?.tag ?? '');
  }

  /// Resolve a plural message for a count (ARB block + CLDR rules). The
  /// block may be embedded in a longer message.
  String trPlural(String key, int count, [Map<String, Object> args = const {}]) {
    final (msg, tag) = trTagged(key);
    final pm = parsePlural(msg);
    if (pm != null) {
      final branch = selectPlural(pm, tag, count);
      if (branch == null) return msg;
      if (pm.prefix.isEmpty && pm.suffix.isEmpty) {
        return interpolatePlural(branch, count, args);
      }
      return interpolate(pm.prefix, args) +
          interpolatePlural(branch, count, args) +
          interpolate(pm.suffix, args);
    }
    return interpolate(msg, args);
  }
}
