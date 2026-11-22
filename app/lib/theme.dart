// Design tokens (docs/DESIGN.md): one accent colour, dark by default, high contrast, one font (the platform's),
// a small type scale, generous spacing, visible focus. Widgets read these, never raw values.

import 'package:material_ui/material_ui.dart';

class Tokens {
  static const accent = Color(0xFF4F8CFF);
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
    // Every screen change is a short fade on every platform (docs/DESIGN.md: motion at most 150 ms).
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final p in TargetPlatform.values) p: const FadeTransitions(),
      },
    ),
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

/// A [Tokens.motion] fade for every route (instead of the platform's 300–500 ms slides); none when the system asks
/// for reduced motion.
class FadeTransitions extends PageTransitionsBuilder {
  const FadeTransitions();

  @override
  Duration get transitionDuration => Tokens.motion;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => MediaQuery.disableAnimationsOf(context)
      ? child
      : FadeTransition(opacity: animation, child: child);
}
