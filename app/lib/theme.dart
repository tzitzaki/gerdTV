// Design tokens (docs/DESIGN.md): one accent colour, dark by default, high contrast, one font (the platform's),
// a small type scale, generous spacing, visible focus. Widgets read these, never raw values.

import 'package:material_ui/material_ui.dart';

class Tokens {
  static const accent = Color(
    0xFFFF7A1A,
  ); // orange: the logo's and the app's one accent

  /// The logo's tile and the Android TV banner's background.
  static const ink = Color(0xFF12121A);
  static const space = 8.0; // the spacing unit: paddings are multiples of it
  static const radius = 12.0;
  static const motion = Duration(milliseconds: 150);

  /// Lists switch to the sidebar layout above this width.
  static const wideLayout = 720.0;
}

ThemeData gerdTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Tokens.accent,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    visualDensity: VisualDensity.standard,
    // A clearly visible focus ring for keyboard and remote navigation.
    focusColor: scheme.primary.withValues(alpha: 0.35),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: Tokens.space * 2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radius),
      ),
    ),
  );
}
