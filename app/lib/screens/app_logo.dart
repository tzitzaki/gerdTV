// gerdTV's logo, drawn in code (docs/DESIGN.md, "Logo"): four mockups the user picks from in Settings → Appearance.
// The same painter draws the in-app mark and the launcher icons: `just logos` renders it to the PNGs under
// app/android and app/ios, and macOS and Linux get PNG bytes from it at runtime (platform_bridge.dart).
// Every logo carries the name: the letters g, T and V are drawn as round strokes (no font, so the icons render the
// same everywhere, also under `flutter test`). Every shape is in units of the icon's side (0..1), so it scales from
// the 24 px rail mark to the 1024 px App Store icon. Debugging a shape: run `just logos` and look at app/build/logos/preview.png.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// The mockups, in the order Settings shows them. The name is stored (app setting `app_logo`) and names the platform
/// icon variants (Android activity alias, iOS alternate icon), so never rename one.
enum AppLogo { gtv, screen, monogram, signal }

/// The stored name back to a logo; unknown or missing names give the default.
AppLogo parseAppLogo(String? name) =>
    AppLogo.values.firstWhere((l) => l.name == name, orElse: () => AppLogo.gtv);

/// The logo as a [px]-square PNG, the tile shrunk by [inset] on every side (macOS icons keep a margin), with a
/// transparent background outside the tile. Used by `just logos` and, at runtime, for the macOS Dock and the Linux
/// window icon.
Future<Uint8List> renderLogoPng(
  AppLogo logo,
  int px, {
  double inset = 0,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final side = px * (1 - 2 * inset);
  canvas.translate(px * inset, px * inset);
  AppLogoPainter(logo).paint(canvas, Size.square(side));
  final image = await recorder.endRecording().toImage(px, px);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

/// The logo inside the app, [size] logical pixels square. Its tile takes the surface colour in the dark theme
/// (owner decision): the icon's blue-black tile showed as a faint square on the warm surfaces. App icons and the light
/// theme use [Tokens.ink].
class AppLogoMark extends StatelessWidget {
  const AppLogoMark({super.key, required this.logo, this.size = 40});
  final AppLogo logo;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: AppLogoPainter(
      logo,
      tileColor: tileFor(Theme.of(context).colorScheme),
    ),
  );

  /// The tile behind the logo inside the app: the logos' white parts need a dark one in the light theme too.
  static Color tileFor(ColorScheme s) =>
      s.brightness == Brightness.light ? Tokens.ink : s.surface;
}

class AppLogoPainter extends CustomPainter {
  const AppLogoPainter(
    this.logo, {
    this.tile = true,
    this.tileColor = Tokens.ink,
  });
  final AppLogo logo;

  /// Draw the rounded background tile. Off for the Android banner, which has its own background.
  final bool tile;

  /// The tile's colour: [Tokens.ink] for app icons; inside the app see [AppLogoMark.tileFor].
  final Color tileColor;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    if (tile) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, s, s),
          Radius.circular(s * 0.22),
        ),
        Paint()..color = tileColor,
      );
    }
    Offset p(double x, double y) => Offset(x * s, y * s);
    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // The letters, as strokes. A lowercase g: a ring (centre x, y, radius r) and a descender down its right side that
    // curls back to the left.
    void g(double x, double y, double r, Paint paint) {
      canvas.drawCircle(p(x, y), r * s, paint);
      canvas.drawPath(
        Path()
          ..moveTo((x + r) * s, (y - r) * s)
          ..lineTo((x + r) * s, (y + 1.18 * r) * s)
          ..arcToPoint(
            p(x - 0.88 * r, y + 1.53 * r),
            radius: Radius.circular(r * s),
            clockwise: true,
          ),
        paint,
      );
    }

    // A capital T and V between x0 and x1, from top to bottom.
    void t(double x0, double x1, double top, double bottom, Paint paint) {
      canvas.drawLine(p(x0, top), p(x1, top), paint);
      canvas.drawLine(p((x0 + x1) / 2, top), p((x0 + x1) / 2, bottom), paint);
    }

    void v(double x0, double x1, double top, double bottom, Paint paint) =>
        canvas.drawPath(
          Path()
            ..moveTo(x0 * s, top * s)
            ..lineTo((x0 + x1) / 2 * s, bottom * s)
            ..lineTo(x1 * s, top * s),
          paint,
        );

    final white = Colors.white;
    switch (logo) {
      case AppLogo.gtv:
        // The wordmark "gTV": the g in the accent colour, TV in white, on one x-height.
        final w = 0.075;
        g(0.27, 0.47, 0.105, stroke(Tokens.accent, w));
        t(0.45, 0.63, 0.365, 0.575, stroke(white, w));
        v(0.66, 0.84, 0.365, 0.575, stroke(white, w));
      case AppLogo.screen:
        // A TV screen in the accent colour with "gTV" cut out of it, on a short stand.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(0.13 * s, 0.20 * s, 0.87 * s, 0.70 * s),
            Radius.circular(0.08 * s),
          ),
          Paint()..color = Tokens.accent,
        );
        final ink = stroke(Tokens.ink, 0.055);
        g(0.30, 0.41, 0.075, ink);
        t(0.44, 0.57, 0.335, 0.485, ink);
        v(0.60, 0.73, 0.335, 0.485, ink);
        canvas.drawLine(p(0.38, 0.81), p(0.62, 0.81), stroke(white, 0.05));
      case AppLogo.monogram:
        // A g whose bowl is a TV screen with antennas, "TV" on the screen.
        final w = stroke(Tokens.accent, 0.075);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(0.22 * s, 0.30 * s, 0.68 * s, 0.62 * s),
            Radius.circular(0.08 * s),
          ),
          w,
        );
        canvas.drawPath(
          Path()
            ..moveTo(0.68 * s, 0.40 * s)
            ..lineTo(0.68 * s, 0.70 * s)
            ..arcToPoint(
              p(0.38, 0.80),
              radius: Radius.circular(0.17 * s),
              clockwise: true,
            ),
          w,
        );
        final antenna = stroke(white, 0.045);
        canvas.drawLine(p(0.45, 0.30), p(0.36, 0.16), antenna);
        canvas.drawLine(p(0.45, 0.30), p(0.56, 0.15), antenna);
        final small = stroke(white, 0.045);
        t(0.31, 0.43, 0.40, 0.52, small);
        v(0.47, 0.59, 0.40, 0.52, small);
      case AppLogo.signal:
        // A g sending: broadcast arcs rise from its top right, fading outwards.
        g(0.40, 0.50, 0.15, stroke(Tokens.accent, 0.09));
        final c = p(0.60, 0.33);
        for (final (i, r) in [0.09, 0.17, 0.25].indexed) {
          canvas.drawArc(
            Rect.fromCircle(center: c, radius: r * s),
            -math.pi / 2,
            math.pi / 2,
            false,
            stroke(white.withValues(alpha: 1 - i * 0.28), 0.055),
          );
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AppLogoPainter old) =>
      old.logo != logo || old.tile != tile || old.tileColor != tileColor;
}
