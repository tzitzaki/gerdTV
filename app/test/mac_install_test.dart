// New, because nothing owned the macOS install's checks: the bundle around the executable, and the requirement the
// new bundle must satisfy, read from codesign's output.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/mac_install.dart';

void main() {
  test('bundle path and designated requirement', () {
    expect(
      bundlePath('/Applications/gerdTV.app/Contents/MacOS/gerdTV'),
      '/Applications/gerdTV.app',
    );
    const out =
        'Executable=/Applications/gerdTV.app/Contents/MacOS/gerdTV\n'
        '# designated => identifier "world.zakis.gerdtv"\n'
        'designated => identifier "world.zakis.gerdtv" and certificate root = H"0123abcd"\n';
    expect(
      designatedRequirement(out),
      'identifier "world.zakis.gerdtv" and certificate root = H"0123abcd"',
    );
    expect(designatedRequirement('code object is not signed at all'), isNull);
  });
}
