// New, because nothing owned "playback keeps going in the background" on the Flutter side: media_kit's Video
// pauses the player when the app goes to the background unless told otherwise. It did on iOS (lock screen, PiP).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/player_screen.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Only constructed, never shown: Video's settings are read without a native player.
class _Controller implements VideoController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('every video view keeps playing in the background', () {
    final v = playerVideo(_Controller(), controls: NoVideoControls);
    expect(v.pauseUponEnteringBackgroundMode, isFalse);
    expect(v.resumeUponEnteringForegroundMode, isFalse);
  });
}
