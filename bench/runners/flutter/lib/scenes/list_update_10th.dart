// Scene: list_update_10th — mutate every 10th row label (100 updates).
// bench-scenes.md Family A: rows 0,10,20,...,990 get a label mutation
// (krausest's "update every 10th row" appends " !!!" to the label).

import 'list_ops_base.dart';

class ListUpdate10thScene extends ListOpsScene {
  ListUpdate10thScene() : super('list_update_10th', startPopulated: true);

  @override
  void performOp() {
    for (int i = 0; i < rows.length; i += 10) {
      rows[i].label = '${rows[i].label} !!!';
    }
  }
}
