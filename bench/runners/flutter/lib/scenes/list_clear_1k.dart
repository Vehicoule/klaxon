// Scene: list_clear_1k — remove all rows -> render empty state.
// bench-scenes.md Family A: the 1000-row model is cleared; the render pass
// that follows shows the empty state ("No rows").

import 'list_ops_base.dart';

class ListClear1kScene extends ListOpsScene {
  ListClear1kScene() : super('list_clear_1k', startPopulated: true);

  @override
  void performOp() {
    rows.clear();
  }
}
