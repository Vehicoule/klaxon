// Scene: list_replace_1k — swap all 1000 row models -> full rebuild render.
// bench-scenes.md Family A: the models are replaced wholesale (new ids ->
// new labels), so the list rebuilds + re-renders every row.

import 'list_ops_base.dart';

class ListReplace1kScene extends ListOpsScene {
  ListReplace1kScene() : super('list_replace_1k', startPopulated: true);

  @override
  void performOp() {
    rows.clear();
    populate(ListOpsScene.kRowCount);
  }
}
