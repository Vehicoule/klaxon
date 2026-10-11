// Scene: list_create_1k — render 1000 rows from empty.
// bench-scenes.md Family A: op_ms = the first-complete-render time of the
// 1000-row list (the scene starts empty; the op populates the models and
// one render pass).

import 'list_ops_base.dart';

class ListCreate1kScene extends ListOpsScene {
  ListCreate1kScene() : super('list_create_1k', startPopulated: false);

  @override
  void performOp() => populate(ListOpsScene.kRowCount);
}
