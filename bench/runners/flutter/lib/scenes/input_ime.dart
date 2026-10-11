// Scene: input_ime — a text field receiving simulated IME text commits.
// Port of src/bench.zig buildInputIme + the tick: the field is focused on
// frame 0 (Klaxon dispatches a pointer click), then every frame commits an
// IME string (CJK + emoji) — a backspace every 12th frame keeps the buffer
// bounded.
//
// Klaxon drives this through its input router (dispatchKey text_input /
// backspace). The Flutter analog is the platform text-input channel's
// programmatic path: mutating the TextEditingController (what the engine does
// when the IME commits composing text). No real keyboard is involved.

import 'package:flutter/material.dart';

import '../harness.dart';

class InputImeScene extends BenchScene {
  InputImeScene() : super('input_ime');

  /// bench.zig IME_STRINGS.
  static const List<String> _imeStrings = <String>[
    'こんにちは',
    '世界',
    '안녕하세요',
    '你好，世界',
    '🌍 ',
    '🎉 ',
  ];

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('input_ime — text field, IME text_input commits (CJK + emoji)',
              style: kBenchTitleStyle),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            decoration: const InputDecoration(
              filled: true,
              labelText: 'Message',
              hintText: 'こんにちは…',
              helperText: 'type CJK / emoji — the buffer follows the caret',
            ),
          ),
        ],
      ),
    );
  }

  @override
  void tick(int frame, BenchHarnessState harness) {
    if (frame == 0) {
      // Klaxon's frame-0 pointer click focuses the field. The tick can run
      // before the scene's first frame has built and laid out the tree —
      // focusing then makes EditableText open the input connection against a
      // RenderEditable that has no size yet — so defer to a post-frame
      // callback (the tree is laid out by then).
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusNode.requestFocus());
    }
    if (frame % 12 == 11) {
      // Backspace: drop the last grapheme (a surrogate pair for emoji).
      final String text = _controller.text;
      if (text.isNotEmpty) {
        var end = text.length - 1;
        final int cu = text.codeUnitAt(end);
        if (cu >= 0xD800 && cu <= 0xDBFF && end > 0) end--;
        final String next = text.substring(0, end);
        _controller.value = TextEditingValue(
            text: next, selection: TextSelection.collapsed(offset: next.length));
      }
    } else {
      final String s = _imeStrings[frame % _imeStrings.length];
      final String next = _controller.text + s;
      _controller.value = TextEditingValue(
          text: next, selection: TextSelection.collapsed(offset: next.length));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
  }
}
