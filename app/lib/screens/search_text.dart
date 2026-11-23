// The matched part of a search result in bold. Matching here is only for display: the core decides what matches
// (word starts, the group, mid-word, typos); this marks every place where a query word appears in the shown text,
// case- and accent-insensitive. A typo hit shows no bold, which is the hint that it was a typo match.

import 'package:material_ui/material_ui.dart';

/// [s] lower-cased with common accents removed, one character for one character, so indices map back to [s].
String foldSameLength(String s) {
  const from = 'äöüéèêëáàâãåóòôõøíìîïúùûçñýÿčšžłńśźżőű';
  const to = 'aoueeeeaaaaaoooooiiiiuuucnyycszlnszzou';
  final out = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    out.write(i < 0 || ch.length != 1 ? ch : to[i]);
  }
  return out.toString();
}

/// The query's words as [foldSameLength] folds them (letters and digits only).
List<String> queryWords(String query) =>
    foldSameLength(query)
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((w) => w.isNotEmpty)
        .toList();

/// [text] with every occurrence of a query word in bold (on top of [style]).
TextSpan highlightSpan(String text, String query, TextStyle? style) {
  final words = queryWords(query);
  final folded = foldSameLength(text);
  if (words.isEmpty || folded.length != text.length) {
    return TextSpan(text: text, style: style);
  }
  final bold = List<bool>.filled(text.length, false);
  for (final w in words) {
    for (var i = folded.indexOf(w); i >= 0; i = folded.indexOf(w, i + 1)) {
      bold.fillRange(i, i + w.length, true);
    }
  }
  final spans = <TextSpan>[];
  var start = 0;
  for (var i = 1; i <= text.length; i++) {
    if (i == text.length || bold[i] != bold[start]) {
      spans.add(
        TextSpan(
          text: text.substring(start, i),
          style: bold[start]
              ? const TextStyle(fontWeight: FontWeight.w800)
              : null,
        ),
      );
      start = i;
    }
  }
  return TextSpan(style: style, children: spans);
}
