// Scene: list_remove_row — delete the middle row.
// bench-scenes.md Family A: row index 500 (the middle of 1000) is removed.

import 'list_ops_base.dart';

class ListRemoveRowScene extends ListOpsScene {
  ListRemoveRowScene() : super('list_remove_row', startPopulated: true);

  @override
  void performOp() {
    rows.removeAt(500);
  }
}
