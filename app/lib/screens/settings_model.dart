// The shape of Settings: categories of entries, and the search that filters them (docs/SPEC.md, "Settings").
// Pure Dart, no widgets are built here, so the filter is tested as a table (app/test/settings_screen_test.dart).
// Debugging a setting that a search doesn't find: add the word the user typed to the entry's keywords (ARB
// `settingsKeywords*`, both languages), not to its title.

import 'package:material_ui/material_ui.dart';

/// One setting (or a small group that only makes sense together, like the guide sources with "Add URL").
class SettingsEntry {
  const SettingsEntry({
    required this.id,
    required this.title,
    this.keywords = '',
    this.section,
    this.actions,
    required this.build,
  });

  /// Stable id, used in widget keys (`settings.entry.<id>`).
  final String id;

  /// What the search matches first; usually the entry's own tile title.
  final String title;

  /// Extra words the search matches (localized, space-separated), e.g. "cache" for the buffer.
  final String keywords;

  /// The subcategory it sits in: one card per section (Streaming: the provider, Premiumize, Your data), holding every
  /// entry of the category with that section, in the order the first one appears. Null: shown without a card (pages
  /// that open from a tile, like Devices & sync). The search matches it too.
  final String? section;

  /// Shown in its card's header, e.g. the provider's ⋮ menu (the first entry of a section that has one).
  final WidgetBuilder? actions;
  final WidgetBuilder build;
}

class SettingsCategory {
  const SettingsCategory({
    required this.id,
    required this.icon,
    required this.title,
    required this.entries,
  });

  /// Stable id, used in widget keys (`settings.cat.<id>`).
  final String id;
  final IconData icon;
  final String title;
  final List<SettingsEntry> entries;
}

/// Lower case, with German umlauts, ß and common accents folded, so "uber" finds "Über" and "strasse" finds "Straße".
String foldForSearch(String s) {
  // Same position, same letter without its accent.
  const from = 'äöüéèêáàâóòôíúçñ';
  const to = 'aoueeeaaaoooiucn';
  final out = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final i = from.indexOf(ch);
    out.write(ch == 'ß' ? 'ss' : (i < 0 ? ch : to[i]));
  }
  return out.toString();
}

/// The categories that still have entries for [query], each holding only its matching entries. A query matches an
/// entry when every word of it appears in the entry's title, keywords or category title. An empty query returns
/// [categories] unchanged.
List<SettingsCategory> filterSettings(
  List<SettingsCategory> categories,
  String query,
) {
  final words = foldForSearch(query)
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return categories;
  final result = <SettingsCategory>[];
  for (final c in categories) {
    final entries = [
      for (final e in c.entries)
        if (words.every(
          foldForSearch(
            '${e.title} ${e.keywords} ${e.section ?? ''} ${c.title}',
          ).contains,
        ))
          e,
    ];
    if (entries.isNotEmpty) {
      result.add(
        SettingsCategory(
          id: c.id,
          icon: c.icon,
          title: c.title,
          entries: entries,
        ),
      );
    }
  }
  return result;
}
