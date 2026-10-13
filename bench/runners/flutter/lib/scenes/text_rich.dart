// Scene: text_rich — 60 paragraphs x 3 lines of mixed-style text (stress).
// bench-scenes.md Family C: 60 paragraphs x 3 lines, mixed: bold/italic
// spans, 3 font sizes (12/16/20 sp), one LTR+RTL bidi line per paragraph
// ("مختصر Klaxon عربي test اختبار") — shaping stress.
//
// Line plan per paragraph (one RichText, \n-joined spans): line 1 = 12 sp
// with bold + italic spans, line 2 = 16 sp, line 3 = the 20 sp bidi string.
// All 60 paragraphs stay mounted (SingleChildScrollView — no virtualization).
// Gap (documented in README): Flutter shapes text at layout time and caches
// it; the tree is static, so the per-frame cost is glyph painting of ~180
// mixed-style lines (layout-time shaping is the analog of Klaxon's shaping
// stress, amortized after first layout).

import 'package:flutter/material.dart';

import '../harness.dart';

/// Fallback chain for the Arabic bidi line (macOS system fonts first, then
/// the Linux/Noto names — fontFamilyFallback is order-preserving, so the
/// extra entries are no-ops on macOS and only matter under Linux/Xvfb).
const List<String> _arabicFallback = <String>[
  'Geeza Pro',
  'Al Nile',
  'Noto Naskh Arabic',
  'Noto Sans Arabic',
  'DejaVu Sans',
  'Arial',
];

class TextRichScene extends BenchScene {
  TextRichScene() : super('text_rich');

  static const int kParagraphs = 60;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < kParagraphs; i++) _paragraph(i),
          ],
        ),
      ),
    );
  }

  Widget _paragraph(int i) {
    const TextStyle s12 = TextStyle(fontSize: 12, color: Colors.white);
    const TextStyle s12b =
        TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold);
    const TextStyle s12i =
        TextStyle(fontSize: 12, color: Colors.white, fontStyle: FontStyle.italic);
    const TextStyle s16 = TextStyle(fontSize: 16, color: Colors.white);
    const TextStyle s20 = TextStyle(fontSize: 20, color: Colors.white);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RichText(
        text: TextSpan(
          children: <InlineSpan>[
            TextSpan(text: 'P$i mixed ', style: s12),
            const TextSpan(text: 'bold', style: s12b),
            const TextSpan(text: ' and ', style: s12),
            const TextSpan(text: 'italic', style: s12i),
            const TextSpan(text: ' spans 0123456789\n', style: s12),
            const TextSpan(
                text:
                    'Second line at sixteen — shaping stress 0123456789\n',
                style: s16),
            // The LTR+RTL bidi line (spec's exact string) at 20 sp.
            TextSpan(
                text: 'مختصر Klaxon عربي test اختبار\n',
                style: s20.copyWith(fontFamilyFallback: _arabicFallback)),
          ],
        ),
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {}
}
