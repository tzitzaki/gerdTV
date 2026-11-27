// Design tokens (docs/DESIGN.md): one accent colour (orange unless the user picks another), dark by default, high
// contrast, one font (the platform's), a small type scale, generous spacing, visible focus. Widgets read these, never
// raw values. The look the user chose (Settings → Appearance → Theme) is a [ThemePrefs], applied by gerdTheme.

import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

class Tokens {
  static const accent = Color(
    0xFFFF7A1A,
  ); // orange: the logo's and the app's default accent

  /// The accent presets (owner decision), orange first; every one keeps AA contrast in both brightnesses
  /// (test/theme_test.dart). The logo stays orange whatever the pick.
  static const accents = [
    accent, // orange
    Color(0xFFE5484D), // red
    Color(0xFFE93D82), // pink
    Color(0xFF8E4EC6), // violet
    Color(0xFF3E63DD), // blue
    Color(0xFF12A594), // teal
    Color(0xFF30A46C), // green
    Color(0xFFFFB224), // gold
  ];

  /// The logo's tile and the Android TV banner's background.
  static const ink = Color(0xFF12121A);
  static const space = 8.0; // the spacing unit: paddings are multiples of it
  static const radius = 12.0;

  /// Every animation's length (owner decision: the cinematic look, about 200–250 ms; none with reduced motion).
  static const motion = Duration(milliseconds: 220);

  /// Lists switch to the sidebar layout above this width.
  static const wideLayout = 720.0;
}

/// The look the user picked (app-wide, Settings → Appearance → Theme; stored by the session in app.json).
/// Defaults (owner decision): dark, orange, neutral surfaces, no pure black.
class ThemePrefs {
  const ThemePrefs({
    this.mode = ThemeMode.dark,
    this.accent = 0,
    this.tinted = false,
    this.black = false,
  });

  final ThemeMode mode;

  /// Index into [Tokens.accents].
  final int accent;

  /// Surfaces tinted by the accent (warm brown-black with orange) instead of neutral grey-black.
  final bool tinted;

  /// Pure black backgrounds in the dark theme (OLED screens).
  final bool black;

  /// From the stored strings; anything unknown keeps the default.
  factory ThemePrefs.parse({
    String? mode,
    String? accent,
    String? tinted,
    String? black,
  }) => ThemePrefs(
    mode: ThemeMode.values.firstWhere(
      (m) => m.name == mode,
      orElse: () => ThemeMode.dark,
    ),
    accent: (int.tryParse(accent ?? '') ?? 0).clamp(
      0,
      Tokens.accents.length - 1,
    ),
    tinted: tinted == 'true',
    black: black == 'true',
  );

  ThemePrefs copyWith({
    ThemeMode? mode,
    int? accent,
    bool? tinted,
    bool? black,
  }) => ThemePrefs(
    mode: mode ?? this.mode,
    accent: accent ?? this.accent,
    tinted: tinted ?? this.tinted,
    black: black ?? this.black,
  );
}

/// The colour scheme for [prefs]: Material's scheme from the accent (fidelity: the accent stays close to the pick
/// instead of a pastel), with the surfaces of a grey scheme unless tinted, and black backgrounds on request (dark).
ColorScheme gerdScheme(Brightness brightness, ThemePrefs prefs) {
  final scheme = ColorScheme.fromSeed(
    seedColor: Tokens.accents[prefs.accent],
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final grey = ColorScheme.fromSeed(
    seedColor: const Color(0xFF808080),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
  );
  var s = prefs.tinted
      ? scheme
      : scheme.copyWith(
          surface: grey.surface,
          onSurface: grey.onSurface,
          onSurfaceVariant: grey.onSurfaceVariant,
          surfaceDim: grey.surfaceDim,
          surfaceBright: grey.surfaceBright,
          surfaceContainerLowest: grey.surfaceContainerLowest,
          surfaceContainerLow: grey.surfaceContainerLow,
          surfaceContainer: grey.surfaceContainer,
          surfaceContainerHigh: grey.surfaceContainerHigh,
          surfaceContainerHighest: grey.surfaceContainerHighest,
          outline: grey.outline,
          outlineVariant: grey.outlineVariant,
          inverseSurface: grey.inverseSurface,
          onInverseSurface: grey.onInverseSurface,
          surfaceTint: Colors.transparent, // no accent haze on raised surfaces
        );
  if (prefs.black && brightness == Brightness.dark) {
    s = s.copyWith(
      surface: Colors.black,
      surfaceDim: Colors.black,
      surfaceContainerLowest: Colors.black,
    );
  }
  return s;
}

ThemeData gerdTheme(
  Brightness brightness, [
  ThemePrefs prefs = const ThemePrefs(),
]) {
  final scheme = gerdScheme(brightness, prefs);
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
/// - everything else (desktop, tablet, TV): a fade with a slight zoom;
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
    // Wide windows: the new page fades in while growing from 97 % (a calm zoom, not a slide).
    final eased = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
    );
    return FadeTransition(
      opacity: eased,
      child: ScaleTransition(
        scale: Tween(begin: 0.97, end: 1.0).animate(eased),
        child: child,
      ),
    );
  }
}

/// Esc and the mouse's back button (the side button) close the top page on every platform (owner decision: desktop
/// has no swipe-back, and pages like Settings → Edit provider were a dead end). Wrapped around the app's navigator
/// (MaterialApp.builder), so it only hears an Esc that nothing focused below it took: the player binds Esc itself, and
/// a dialog, sheet or menu (a PopupRoute) is left to Flutter's own Esc, which closes it only when it may be dismissed.
/// On the first page maybePop does nothing; a page that must not close (a running login test) says so with PopScope.
/// Not a DismissIntent action: Flutter stops at the page route's own (disabled) dismiss action and goes no further.
/// Debugging: Esc doing nothing on a page usually means the focus is outside the app's navigator.
class BackKeys extends StatelessWidget {
  const BackKeys({super.key, required this.navigator, required this.child});
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  bool _back() {
    final focused = FocusManager.instance.primaryFocus?.context;
    final route = focused == null ? null : ModalRoute.of(focused);
    if (route is PopupRoute) return false;
    navigator.currentState?.maybePop();
    return true;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (e) {
      if (e.buttons & kBackMouseButton != 0) _back();
    },
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) =>
          event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape &&
              _back()
          ? KeyEventResult.handled
          : KeyEventResult.ignored,
      child: child,
    ),
  );
}
