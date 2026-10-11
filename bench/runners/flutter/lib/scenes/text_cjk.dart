// Scene: text_cjk — Chinese / Japanese / Korean text (shaping stress).
// Port of src/bench.zig buildTextCjk: the same four paragraphs + title.
// The default macOS Flutter font has no CJK glyphs, so the paragraphs carry a
// fontFamilyFallback chain of the system CJK fonts (PingFang SC /
// Hiragino Sans / Apple SD Gothic Neo).

import 'package:flutter/material.dart';

import '../harness.dart';

const List<String> _cjkFallback = <String>[
  'PingFang SC',
  'Hiragino Sans',
  'Apple SD Gothic Neo',
  'Noto Sans CJK SC',
  'Arial Unicode MS',
];

class TextCjkScene extends BenchScene {
  TextCjkScene() : super('text_cjk');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('text_cjk — CJK shaping (中文 / 日本語 / 한국어)',
              style: kBenchTitleStyle),
          const SizedBox(height: 10),
          _para('你好，世界！Klaxon 是一个用 Zig 编写的 UI 框架。', 22),
          const SizedBox(height: 10),
          _para('こんにちは、世界！Klaxon は Zig で書かれた UI フレームワークです。', 22),
          const SizedBox(height: 10),
          _para('안녕하세요, 세계! Klaxon은 Zig로 작성된 UI 프레임워크입니다.', 22),
          const SizedBox(height: 10),
          _para('混ぜるな危険 — CJK + Latin + emoji 🌍🎉', 18,
              color: const Color(0xFFFFD54F)),
        ],
      ),
    );
  }

  Widget _para(String text, double size, {Color color = Colors.white}) {
    return Text(
      text,
      style: TextStyle(
        fontSize: size,
        color: color,
        fontFamilyFallback: _cjkFallback,
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {}
}
