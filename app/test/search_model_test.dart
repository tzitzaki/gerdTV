// Owns: search as you type never shows an answer to an older keystroke (stale responses are dropped).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/services/search_model.dart';
import 'package:gerdtv/src/rust/api/library.dart';

ItemInfo item(String name) => ItemInfo(
  key: 'live:$name',
  kind: ItemKind.live,
  name: name,
  category: 'g',
  logo: '',
);

void main() {
  test('a slow answer to an older keystroke is dropped', () async {
    final pending = <String, Completer<SearchPage>>{};
    final model = SearchModel((seq, q, kind, offset) {
      final c = Completer<SearchPage>();
      pending[q] = c;
      return c.future.then(
        (p) =>
            SearchPage(seq: BigInt.from(seq), hits: p.hits, counts: p.counts),
      );
    });
    final first = model.set('ar');
    final second = model.set('ard');
    // "ard" answers first, then the stale "ar" arrives.
    pending['ard']!.complete(
      SearchPage(seq: BigInt.zero, hits: [item('ARD')], counts: const []),
    );
    await second;
    pending['ar']!.complete(
      SearchPage(
        seq: BigInt.zero,
        hits: [item('Arte'), item('ARD')],
        counts: const [],
      ),
    );
    await first;
    expect(model.hits.map((h) => h.name), ['ARD']);
    // Clearing the field empties the list without a query.
    await model.set('');
    expect(model.hits, isEmpty);
  });
}
