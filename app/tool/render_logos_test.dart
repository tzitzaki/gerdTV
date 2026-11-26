// `just logos`: renders every AppLogo (lib/screens/app_logo.dart) into the launcher icon files, and a preview sheet
// to build/logos/preview.png. Run it after changing a logo's drawing and commit the PNGs it writes. It lives outside
// test/ so `flutter test` doesn't rewrite the icons on every run.
//   Android: res/mipmap-*dpi/ic_launcher.png (the default logo) and ic_launcher_<logo>.png (the others), one launcher
//            activity alias each (AndroidManifest.xml); the TV banners res/drawable-xhdpi/banner.png and
//            banner_<logo>.png (320 × 180, the logo large on its dark background; the Google TV home's wide tile).
//   iOS:     Assets.xcassets/AppIcon.appiconset (the default) and AppIcon-<logo>.appiconset (alternate icons), each a
//            single 1024 px image, which Xcode 14 and later scale for every size.
//   macOS:   Assets.xcassets/AppIcon.appiconset, the default logo at every size Contents.json names, with a margin.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/app_logo.dart';
import 'package:gerdtv/theme.dart';

const defaultLogo = AppLogo.gtv;

Future<void> write(String path, List<int> bytes) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  await f.writeAsBytes(bytes);
}

/// An iOS app icon set with one 1024 px image.
Future<void> iosSet(String dir, AppLogo logo) async {
  await write('$dir/icon.png', await renderLogoPng(logo, 1024));
  await write(
    '$dir/Contents.json',
    utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert({
        'images': [
          {'filename': 'icon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
        ],
        'info': {'author': 'xcode', 'version': 1},
      })}\n',
    ),
  );
}

/// An Android TV banner: 320 × 180 (xhdpi), the logo without its tile on the tile's colour, scaled so its drawing
/// (measured from the painted pixels, as each logo fills its square differently) takes 70 % of the height or 85 % of
/// the width, whichever is reached first.
Future<List<int>> banner(AppLogo logo) async {
  const w = 320, h = 180, big = 512;
  // The logo alone, large, to measure where it paints.
  var recorder = PictureRecorder();
  AppLogoPainter(
    logo,
    tile: false,
  ).paint(Canvas(recorder), const Size.square(big * 1.0));
  final drawn = await recorder.endRecording().toImage(big, big);
  final rgba = (await drawn.toByteData(format: ImageByteFormat.rawRgba))!;
  var (left, top, right, bottom) = (big, big, 0, 0);
  for (var y = 0; y < big; y++) {
    for (var x = 0; x < big; x++) {
      if (rgba.getUint8((y * big + x) * 4 + 3) > 0) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  final src = Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right + 1.0,
    bottom + 1.0,
  );
  final scale = [
    h * 0.7 / src.height,
    w * 0.85 / src.width,
  ].reduce((a, b) => a < b ? a : b);
  final dst = Rect.fromCenter(
    center: Offset(w / 2, h / 2),
    width: src.width * scale,
    height: src.height * scale,
  );
  recorder = PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = Tokens.ink,
  );
  canvas.drawImageRect(
    drawn,
    src,
    dst,
    Paint()..filterQuality = FilterQuality.high,
  );
  final image = await recorder.endRecording().toImage(w, h);
  final png = await image.toByteData(format: ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

void main() {
  testWidgets('render launcher icons', (tester) async {
    await tester.runAsync(() async {
      // Android: the legacy launcher sizes (48 dp at each density).
      const android = {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      };
      for (final MapEntry(key: dpi, value: px) in android.entries) {
        final res = 'android/app/src/main/res/mipmap-$dpi';
        for (final logo in AppLogo.values.where((l) => l != defaultLogo)) {
          await write(
            '$res/ic_launcher_${logo.name}.png',
            await renderLogoPng(logo, px),
          );
        }
        await write(
          '$res/ic_launcher.png',
          await renderLogoPng(defaultLogo, px),
        );
      }

      // Android TV banners, one per launcher alias.
      for (final logo in AppLogo.values) {
        final name = logo == defaultLogo ? 'banner' : 'banner_${logo.name}';
        await write(
          'android/app/src/main/res/drawable-xhdpi/$name.png',
          await banner(logo),
        );
      }

      // iOS: the default set plus one alternate set per other logo.
      const ios = 'ios/Runner/Assets.xcassets';
      final old = Directory('$ios/AppIcon.appiconset');
      if (old.existsSync()) await old.delete(recursive: true);
      await iosSet('$ios/AppIcon.appiconset', defaultLogo);
      for (final logo in AppLogo.values.where((l) => l != defaultLogo)) {
        await iosSet('$ios/AppIcon-${logo.name}.appiconset', logo);
      }

      // macOS: every file the existing Contents.json names, at its pixel size (size × scale), ~10 % margin.
      const mac = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
      final contents = jsonDecode(
        File('$mac/Contents.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      for (final img
          in (contents['images'] as List).cast<Map<String, dynamic>>()) {
        final pt = double.parse((img['size'] as String).split('x').first);
        final scale = int.parse((img['scale'] as String).replaceAll('x', ''));
        await write(
          '$mac/${img['filename']}',
          await renderLogoPng(defaultLogo, (pt * scale).round(), inset: 0.1),
        );
      }

      // Preview: each logo at 192 and 48 px in a row, for looking at the drawings.
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1000, 280),
        Paint()..color = const Color(0xFF2A2A33),
      );
      for (final (i, logo) in AppLogo.values.indexed) {
        canvas.save();
        canvas.translate(24 + i * 244.0, 24);
        AppLogoPainter(logo).paint(canvas, const Size.square(192));
        canvas.translate(72, 208);
        AppLogoPainter(logo).paint(canvas, const Size.square(48));
        canvas.restore();
      }
      final image = await recorder.endRecording().toImage(1000, 280);
      final png = await image.toByteData(format: ImageByteFormat.png);
      await write('build/logos/preview.png', png!.buffer.asUint8List());
    });
  });
}
