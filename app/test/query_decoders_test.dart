// New, because nothing owned the rule "the chosen libmpv stays chosen": the own engine crashed on macOS and iOS
// (EXC_BAD_ACCESS in Mpv's mp_dispatch_lock) because the video plugin's queryDecoders re-ran media_kit's library
// lookup without an argument. That switched to the bundled Mpv.framework and handed it GerdMpv's handle.
// Here a full path stands in for the own build: the default lookup would answer the short name "libmpv.so".
// ignore_for_file: implementation_imports
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/generated/libmpv/bindings.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit_video/src/utils/query_decoders.dart';

void main() {
  const lib = '/usr/lib/x86_64-linux-gnu/libmpv.so.2';

  test(
    'reading the decoders keeps the chosen libmpv',
    () async {
      NativeLibrary.ensureInitialized(libmpv: lib);
      final mpv = MPV(DynamicLibrary.open(lib));
      final handle = mpv.mpv_create();
      mpv.mpv_initialize(handle);
      final decoders = await queryDecoders(handle.address);
      expect(decoders, isNotEmpty, reason: 'decoder-list read from the handle');
      expect(NativeLibrary.path, lib);
      mpv.mpv_terminate_destroy(handle);
    },
    skip: File(lib).existsSync() ? false : 'needs the system libmpv',
  );
}
