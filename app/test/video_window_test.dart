// The player window's sizing rules (lib/platform/video_window.dart): the content keeps the picture's ratio and never
// outgrows the screen; stored sizes that don't parse are ignored. The window itself is checked in
// integration_test/mini_player_test.dart.
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/video_window.dart';

void main() {
  test('the content keeps the ratio and fits the screen', () {
    const screen = Size(1600, 900);
    // (width asked, ratio) → content
    final table = <(double, double), Size>{
      (1280, 16 / 9): const Size(1280, 720),
      (960, 4 / 3): const Size(960, 720),
      (2000, 16 / 9): const Size(1600, 900), // too wide: the screen's width
      (1400, 4 / 3): const Size(1200, 900), // too high: the screen's height
      (900, 2.39): const Size(900, 377), // cinemascope
    };
    table.forEach((asked, content) {
      expect(fitToRatio(asked.$1, asked.$2, screen), content, reason: '$asked');
    });
  });

  test('stored sizes round-trip; anything else is ignored', () {
    expect(
      parseWindowSize(formatWindowSize(const Size(1280, 720))),
      const Size(1280, 720),
    );
    for (final bad in [null, '', '1280', 'x720', '0x720', 'axb', '1x2x3']) {
      expect(parseWindowSize(bad), isNull, reason: '$bad');
    }
  });
}
