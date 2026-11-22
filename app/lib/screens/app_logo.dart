// gerdTV's logo, drawn in code (docs/DESIGN.md, "Logo"): four mockups the user picks from in Settings → Appearance.
// The same painter draws the in-app mark and the launcher icons: `just logos` renders it to the PNGs under
// app/android and app/ios, and macOS and Linux get PNG bytes from it at runtime (app_logo_platform.dart).
// Every shape is in units of the icon's side (0..1), so it scales from the 24 px rail mark to the 1024 px App Store
// icon. Debugging a shape: run `just logos` and look at app/build/logos/preview.png.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../theme.dart';

/// The mockups, in the order Settings shows them. The name is stored (app setting `app_logo`) and names the platform
/// icon variants (Android activity alias, iOS alternate icon), so never rename one.
enum AppLogo { screen, monogram, signal, frame }

/// The stored name back to a logo; unknown or missing names give the default.
AppLogo parseAppLogo(String? name) => AppLogo.values.firstWhere(
  (l) => l.name == name,
  orElse: () => AppLogo.screen,
);

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

/// The logo on its rounded dark tile, [size] logical pixels square.
class AppLogoMark extends StatelessWidget {
  const AppLogoMark({super.key, required this.logo, this.size = 40});
  final AppLogo logo;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: AppLogoPainter(logo));
}

class AppLogoPainter extends CustomPainter {
  const AppLogoPainter(this.logo, {this.tile = true});
  final AppLogo logo;

  /// Draw the rounded background tile. Off for the Android banner, which has its own background.
  final bool tile;

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
        Paint()..color = Tokens.ink,
      );
    }
    final accent = Paint()
      ..color = Tokens.accent
      ..isAntiAlias = true;
    final ink = Paint()..color = Tokens.ink;
    Offset p(double x, double y) => Offset(x * s, y * s);
    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * s
      ..strokeCap = StrokeCap.round;

    switch (logo) {
      case AppLogo.screen:
        // A TV screen with a play triangle cut out of it, on a short stand.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(0.16 * s, 0.22 * s, 0.84 * s, 0.70 * s),
            Radius.circular(0.08 * s),
          ),
          accent,
        );
        canvas.drawPath(
          Path()
            ..moveTo(0.43 * s, 0.34 * s)
            ..lineTo(0.62 * s, 0.46 * s)
            ..lineTo(0.43 * s, 0.58 * s)
            ..close(),
          ink,
        );
        canvas.drawLine(
          p(0.38, 0.80),
          p(0.62, 0.80),
          stroke(Colors.white, 0.05),
        );
      case AppLogo.monogram:
        // A lowercase "g": a ring and a descender that curls back like a cable.
        final w = stroke(Tokens.accent, 0.10);
        canvas.drawCircle(p(0.47, 0.42), 0.17 * s, w);
        canvas.drawPath(
          Path()
            ..moveTo(0.64 * s, 0.26 * s)
            ..lineTo(0.64 * s, 0.62 * s)
            ..arcToPoint(
              p(0.32, 0.68),
              radius: Radius.circular(0.17 * s),
              clockwise: true,
            ),
          w,
        );
        canvas.drawCircle(
          p(0.47, 0.42),
          0.05 * s,
          Paint()..color = Colors.white,
        );
      case AppLogo.signal:
        // A broadcast dot with three arcs rising from it, fading outwards.
        final c = p(0.5, 0.66);
        canvas.drawCircle(c, 0.07 * s, accent);
        for (final (i, r) in [0.18, 0.30, 0.42].indexed) {
          canvas.drawArc(
            Rect.fromCircle(center: c, radius: r * s),
            -math.pi * 0.78,
            math.pi * 0.56,
            false,
            stroke(Colors.white.withValues(alpha: 1 - i * 0.28), 0.065),
          );
        }
      case AppLogo.frame:
        // A viewfinder: four corner brackets around a play triangle.
        final w = stroke(Colors.white, 0.06);
        const a = 0.20, b = 0.80, l = 0.16; // frame corners and bracket length
        for (final (x, y, dx, dy) in [
          (a, a, 1.0, 1.0),
          (b, a, -1.0, 1.0),
          (a, b, 1.0, -1.0),
          (b, b, -1.0, -1.0),
        ]) {
          canvas.drawPath(
            Path()
              ..moveTo(x * s, (y + dy * l) * s)
              ..lineTo(x * s, y * s)
              ..lineTo((x + dx * l) * s, y * s),
            w..strokeJoin = StrokeJoin.round,
          );
        }
        canvas.drawPath(
          Path()
            ..moveTo(0.42 * s, 0.35 * s)
            ..lineTo(0.66 * s, 0.50 * s)
            ..lineTo(0.42 * s, 0.65 * s)
            ..close(),
          accent,
        );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(AppLogoPainter old) =>
      old.logo != logo || old.tile != tile;
}
