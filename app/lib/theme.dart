// Design tokens (docs/DESIGN.md): one accent colour, dark by default, high contrast, one font (the platform's),
// a small type scale, generous spacing, visible focus. Widgets read these, never raw values.

import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
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
    // Screen changes (docs/DESIGN.md, motion): a short fade, or on phones the iOS-style slide with edge swipe-back.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final p in TargetPlatform.values) p: const RouteTransitions(),
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

/// Every route's transition, in [Tokens.motion] (instead of the platform's 300–500 ms slides):
/// - phones (iOS and Android below [Tokens.wideLayout], the shell's phone layout): the iOS slide, whose left-edge
///   swipe closes the page (owner decision: swipe-back on phones; Android's system back keeps working too);
/// - everything else (desktop, tablet, TV): a fade;
/// - none when the system asks for reduced motion (then the page just appears; Back still closes it).
/// Debugging: a page that won't swipe back usually isn't a PageRoute, or the window is wider than the phone layout.
class RouteTransitions extends PageTransitionsBuilder {
  const RouteTransitions();

  static const _slide = CupertinoPageTransitionsBuilder();

  @override
  Duration get transitionDuration => Tokens.motion;

  /// Phones get the slide with swipe-back.
  static bool swipeBack(BuildContext context) =>
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android) &&
      MediaQuery.sizeOf(context).width < Tokens.wideLayout;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    if (swipeBack(context)) {
      return _slide.buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    return FadeTransition(opacity: animation, child: child);
  }
}
