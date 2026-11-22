// Search as you type (docs/SPEC.md, global search): every keystroke sends a numbered query; an answer is shown
// only if it belongs to the newest query, so a slow answer to "ar" can never overwrite the one for "ard".
// No debounce: the core answers in milliseconds.

import 'package:flutter/foundation.dart';

import '../src/rust/api/library.dart';

typedef SearchFn = Future<SearchPage> Function(
  int seq,
  String query,
  ItemKind? kind,
  int offset,
);

class SearchModel extends ChangeNotifier {
  SearchModel(this._search);

  final SearchFn _search;
  static const pageSize = 50;

  String query = '';
  ItemKind? kind;
  List<ItemInfo> hits = const [];
  List<KindCount> counts = const [];
  String? error;
  bool _more = false;
  int _seq = 0;

  bool get hasMore => _more;

  /// A keystroke (or a type chip): starts a new numbered query.
  Future<void> set(
    String q, {
    ItemKind? kindFilter,
    bool keepKind = true,
  }) async {
    query = q;
    if (!keepKind) kind = kindFilter;
    final seq = ++_seq;
    if (q.trim().isEmpty) {
      hits = const [];
      counts = const [];
      notifyListeners();
      return;
    }
    try {
      final page = await _search(seq, q, kind, 0);
      if (page.seq.toInt() != _seq) {
        return; // a newer keystroke is already on its way: drop this answer
      }
      hits = page.hits;
      counts = page.counts;
      _more = page.hits.length == pageSize;
      error = null;
    } catch (e) {
      if (seq != _seq) return;
      error = '$e';
    }
    notifyListeners();
  }

  void setKind(ItemKind? k) {
    kind = k;
    set(query);
  }

  /// The next page (infinite scroll); ignored while a newer query exists.
  Future<void> loadMore() async {
    if (!_more) return;
    final seq = _seq;
    _more = false;
    final page = await _search(seq, query, kind, hits.length);
    if (seq != _seq) return;
    hits = [...hits, ...page.hits];
    _more = page.hits.length == pageSize;
    notifyListeners();
  }
}
