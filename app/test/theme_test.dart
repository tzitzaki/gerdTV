// New, because nothing owned the theme's contrast (owner decision: every accent, both brightnesses, neutral or tinted
// surfaces, pure black): text on surfaces and on the accent stays at WCAG AA (4.5:1), and the accent stands out from
// the background (3:1, for focus rings, the now line and selected states).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/app_logo.dart';
import 'package:gerdtv/theme.dart';
import 'package:material_ui/material_ui.dart';

double contrast(Color a, Color b) {
  final (x, y) = (a.computeLuminance(), b.computeLuminance());
  return (max(x, y) + 0.05) / (min(x, y) + 0.05);
}

void main() {
  test('every accent keeps AA contrast in every variant', () {
    for (var accent = 0; accent < Tokens.accents.length; accent++) {
      for (final brightness in Brightness.values) {
        for (final tinted in [false, true]) {
          for (final black in [false, true]) {
            final s = gerdScheme(
              brightness,
              ThemePrefs(accent: accent, tinted: tinted, black: black),
            );
            final what =
                'accent $accent $brightness tinted $tinted black $black';
            expect(
              contrast(Colors.white, AppLogoMark.tileFor(s)),
              greaterThanOrEqualTo(3),
              reason: 'the logo\'s white letters, $what',
            );
            expect(
              contrast(s.onSurface, s.surface),
              greaterThanOrEqualTo(4.5),
              reason: what,
            );
            expect(
              contrast(s.onSurfaceVariant, s.surfaceContainerHigh),
              greaterThanOrEqualTo(4.5),
              reason: what,
            );
            expect(
              contrast(s.onPrimary, s.primary),
              greaterThanOrEqualTo(4.5),
              reason: what,
            );
            expect(
              contrast(s.onPrimaryContainer, s.primaryContainer),
              greaterThanOrEqualTo(4.5),
              reason: what,
            );
            expect(
              contrast(s.primary, s.surface),
              greaterThanOrEqualTo(3),
              reason: what,
            );
          }
        }
      }
    }
  });

  test('neutral surfaces are grey, pure black is black (dark only)', () {
    final neutral = gerdScheme(Brightness.dark, const ThemePrefs());
    final c = neutral.surface;
    expect(
      (c.r - c.g).abs() < 0.02 && (c.g - c.b).abs() < 0.02,
      isTrue,
      reason: '$c',
    );
    expect(
      gerdScheme(Brightness.dark, const ThemePrefs(black: true)).surface,
      Colors.black,
    );
    expect(
      gerdScheme(Brightness.light, const ThemePrefs(black: true)).surface,
      isNot(Colors.black),
    );
  });
}
