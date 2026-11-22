// `just logos`: renders every AppLogo (lib/screens/app_logo.dart) into the launcher icon files, and a preview sheet
// to build/logos/preview.png. Run it after changing a logo's drawing and commit the PNGs it writes. It lives outside
// test/ so `flutter test` doesn't rewrite the icons on every run.
//   Android: res/mipmap-*dpi/ic_launcher.png (the default logo) and ic_launcher_<logo>.png (the others), one launcher
//            activity alias each (AndroidManifest.xml).
//   iOS:     Assets.xcassets/AppIcon.appiconset (the default) and AppIcon-<logo>.appiconset (alternate icons), each a
//            single 1024 px image, which Xcode 14 and later scale for every size.
//   macOS:   Assets.xcassets/AppIcon.appiconset, the default logo at every size Contents.json names, with a margin.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/app_logo.dart';

const defaultLogo = AppLogo.screen;

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
