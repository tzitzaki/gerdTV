// Search as you type (docs/SPEC.md, Search): every keystroke sends a numbered query; an answer is shown only if it
// belongs to the newest query, so a slow answer to "ar" can never overwrite the one for "ard".
// One model per search field: a section (Live TV, Movies, Series) or a group inside one; [category] switches between
// the group (its id) and the whole section (null, the "All groups" chip). No debounce: the core answers in milliseconds.

import 'package:flutter/foundation.dart';

import '../src/rust/api/library.dart';

typedef SearchFn = Future<SearchPage> Function(
  int seq,
  String query,
  String? category,
  int offset,
);

class SearchModel extends ChangeNotifier {
  SearchModel(this._search, {this.category});

  final SearchFn _search;
  static const pageSize = 50;

  String query = '';

  /// The group searched (its id), or null for the whole section.
  String? category;
  List<ItemInfo> hits = const [];

  /// Totals per kind over every section (the chip and the "Also in" line).
  List<KindCount> counts = const [];

  /// Groups whose name matches (whole-section searches only).
  List<GroupHit> groups = const [];
  String? error;
  bool _more = false;
  int _seq = 0;

  bool get hasMore => _more;

  /// A keystroke: starts a new numbered query.
  Future<void> set(String q) async {
    query = q;
    final seq = ++_seq;
    if (q.trim().isEmpty) {
      hits = const [];
      counts = const [];
      groups = const [];
      notifyListeners();
      return;
    }
    try {
      final page = await _search(seq, q, category, 0);
      if (page.seq.toInt() != _seq) {
        return; // a newer keystroke is already on its way: drop this answer
      }
      hits = page.hits;
      counts = page.counts;
      groups = page.groups;
      _more = page.hits.length == pageSize;
      error = null;
    } catch (e) {
      if (seq != _seq) return;
      error = '$e';
    }
    notifyListeners();
  }

  /// The "All groups" chip: widen to the whole section (null) or back to the group.
  void setCategory(String? c) {
    category = c;
    set(query);
  }

  /// The next page (infinite scroll); ignored while a newer query exists.
  Future<void> loadMore() async {
    if (!_more) return;
    final seq = _seq;
    _more = false;
    final page = await _search(seq, query, category, hits.length);
    if (seq != _seq) return;
    hits = [...hits, ...page.hits];
    _more = page.hits.length == pageSize;
    notifyListeners();
  }
}
