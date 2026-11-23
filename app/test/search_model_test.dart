// Owns: search as you type never shows an answer to an older keystroke (stale responses are dropped), and the
// "All groups" chip re-asks the same query for the whole section.
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
  archiveDays: 0,
  group: '',
);

void main() {
  test('a slow answer to an older keystroke is dropped', () async {
    final pending = <String, Completer<SearchPage>>{};
    final model = SearchModel((seq, q, category, offset) {
      final c = Completer<SearchPage>();
      pending[q] = c;
      return c.future.then(
        (p) =>
            SearchPage(
              seq: BigInt.from(seq),
              hits: p.hits,
              counts: p.counts,
              groups: const [],
            ),
      );
    });
    final first = model.set('ar');
    final second = model.set('ard');
    // "ard" answers first, then the stale "ar" arrives.
    pending['ard']!.complete(
      SearchPage(
        seq: BigInt.zero,
        hits: [item('ARD')],
        counts: const [],
        groups: const [],
      ),
    );
    await second;
    pending['ar']!.complete(
      SearchPage(
        seq: BigInt.zero,
        hits: [item('Arte'), item('ARD')],
        counts: const [],
        groups: const [],
      ),
    );
    await first;
    expect(model.hits.map((h) => h.name), ['ARD']);
    // Clearing the field empties the list without a query.
    await model.set('');
    expect(model.hits, isEmpty);
  });
  test('the All groups chip asks again without the group', () async {
    final asked = <String?>[];
    final model = SearchModel((seq, q, category, offset) async {
      asked.add(category);
      return SearchPage(
        seq: BigInt.from(seq),
        hits: [item(category ?? 'all')],
        counts: const [],
        groups: const [],
      );
    }, category: 'g1');
    await model.set('dazn');
    model.setCategory(null);
    await Future<void>.delayed(Duration.zero);
    expect(asked, ['g1', null]);
    expect(model.hits.map((h) => h.name), ['all']);
  });
}
