// New, because nothing owned touch gestures (owner decision): on phones a fast horizontal fling switches to the
// neighbouring section (none where the shell turns it off, the Guide), and the player gestures follow their setting
// (seek only in movies and episodes, volume everywhere, nothing when off).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/player_screen.dart';
import 'package:gerdtv/screens/shell.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart';

void main() {
  for (final (enabled, offset, want) in [
    (true, const Offset(-300, 0), 'next'),
    (true, const Offset(300, 0), 'previous'),
    (false, const Offset(-300, 0), null), // the Guide
  ]) {
    testWidgets('fling $offset, enabled $enabled → $want', (tester) async {
      final got = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SectionSwipe(
            enabled: enabled,
            onNext: () => got.add('next'),
            onPrevious: () => got.add('previous'),
            child: const SizedBox.expand(child: Text('section')),
          ),
        ),
      );
      await tester.fling(find.text('section'), offset, 1500);
      await tester.pumpAndSettle();
      expect(got, [?want]);
    });
  }

  testWidgets('a slow drag does not switch', (tester) async {
    final got = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SectionSwipe(
          onNext: () => got.add('next'),
          child: const SizedBox.expand(child: Text('section')),
        ),
      ),
    );
    await tester.timedDrag(
      find.text('section'),
      const Offset(-200, 0),
      const Duration(seconds: 2),
    );
    await tester.pumpAndSettle();
    expect(got, isEmpty);
  });

  test('player gestures follow the setting and the kind', () {
    for (final (enabled, vod, seek, volume) in [
      (true, true, true, true),
      (true, false, false, true), // live: no seek swipe
      (false, true, false, false),
    ]) {
      final t = withGestures(
        kDefaultMaterialVideoControlsThemeData,
        enabled: enabled,
        vod: vod,
        volume: 1.4, // mpv allows more than 100 %; the slider starts at its top
        onVolume: (_) {},
      );
      expect(
        (t.seekGesture, t.seekOnDoubleTap, t.volumeGesture),
        (seek, seek, volume),
        reason: 'enabled $enabled vod $vod',
      );
      expect(t.brightnessGesture, isFalse);
      expect(t.initialVolume, 1.0);
      expect(t.onVolumeChanged, isNotNull);
    }
  });
}
