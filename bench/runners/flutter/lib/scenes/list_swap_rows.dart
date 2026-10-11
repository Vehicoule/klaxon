// Scene: list_swap_rows — swap row 5 <-> row 995 contents (not widgets).
// bench-scenes.md Family A: the models at positions 5 and 995 are swapped;
// the widgets stay in place (no keys — Flutter diffs the children in place
// and rebuilds their content, matching "contents, not widgets").

import 'list_ops_base.dart';

class ListSwapRowsScene extends ListOpsScene {
  ListSwapRowsScene() : super('list_swap_rows', startPopulated: true);

  @override
  void performOp() {
    final ListRowModel tmp = rows[5];
    rows[5] = rows[995];
    rows[995] = tmp;
  }
}
