// Owns: search results bold every place a query word appears, ignoring case and accents (display only; the core
// decides what matches).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/search_text.dart';
import 'package:material_ui/material_ui.dart';

/// The bold parts of [text] for [query], e.g. ['DAZN'].
List<String> bold(String text, String query) => [
  for (final s
      in (highlightSpan(text, query, null).children ?? const [])
          .cast<TextSpan>())
    if (s.style?.fontWeight != null) s.text!,
];

void main() {
  test(
    'query words are bold wherever they appear, case and accents folded',
    () {
      for (final (text, query, parts) in [
        ('DAZN 1 HD', 'dazn', ['DAZN']),
        ('Eurosport 1', 'sport', ['sport']),
        ('BR München', 'munchen', ['München']),
        ('Das Erste', 'das ers', ['Das', 'Ers']),
        ('DAZN 1 HD', 'dazm', <String>[]), // a typo hit: nothing to bold
        ('Arte', '', <String>[]),
      ]) {
        expect(bold(text, query), parts, reason: '$text / $query');
      }
    },
  );
}
