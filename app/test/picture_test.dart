// New, because nothing owns the picture's shape: an unknown or missing stored format is the normal one, and
// deinterlacing off puts the decoder back.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/player/picture.dart';

void main() {
  test('formats are stored by name; anything else is the normal picture', () {
    for (final f in PictureFormat.values) {
      expect(PictureFormat.parse(f.name), f);
    }
    for (final s in [null, '', 'bogus']) {
      expect(PictureFormat.parse(s), PictureFormat.fit);
    }
  });

  test('deinterlacing needs copied frames, and off restores the decoder', () {
    for (final (on, want) in [
      (true, {'deinterlace': 'auto', 'hwdec': 'auto-copy'}),
      (false, {'deinterlace': 'no', 'hwdec': 'auto-safe'}),
    ]) {
      expect({
        for (final o in deinterlaceOptions(on: on, defaultHwdec: 'auto-safe'))
          o.name: o.value,
      }, want);
    }
  });
}
