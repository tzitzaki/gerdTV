// How the picture fills the player (per item, any engine: Flutter scales the texture) and deinterlacing (mpv only).
// Debugging combed edges with deinterlacing on: mpv's `hwdec-current` must be empty or end in "-copy" (a zero-copy
// frame passes the deinterlacer unchanged), and the stream must flag its frames as interlaced.

import 'package:flutter/painting.dart';

import '../src/rust/api/playback.dart';

const settingDeinterlace = 'deinterlace';

/// [name]: stored; [fit] and [aspect]: for media_kit's Video.
enum PictureFormat {
  fit(BoxFit.contain, null),
  zoom(BoxFit.cover, null),
  stretch(BoxFit.fill, null),
  wide(BoxFit.contain, 16 / 9),
  classic(BoxFit.contain, 4 / 3);

  const PictureFormat(this.boxFit, this.aspect);
  final BoxFit boxFit;
  final double? aspect;

  static PictureFormat parse(String? s) =>
      values.firstWhere((f) => f.name == s, orElse: () => fit);

  /// The profile setting that remembers an item's format.
  static String settingFor(String key) => 'picture:$key';
}

/// What mpv gets before a start. [defaultHwdec] is the decoder choice the video controller made. "yes" comes first
/// for mpv 0.36 (media_kit's), which may not know "auto" and then keeps "yes"; newer ones end on "auto", which leaves
/// progressive frames alone.
List<MpvOption> deinterlaceOptions({
  required bool on,
  required String defaultHwdec,
}) => [
  if (on) ...const [
    MpvOption(name: 'deinterlace', value: 'yes'),
    MpvOption(name: 'deinterlace', value: 'auto'),
    MpvOption(name: 'hwdec', value: 'auto-copy'),
  ] else ...[
    const MpvOption(name: 'deinterlace', value: 'no'),
    MpvOption(name: 'hwdec', value: defaultHwdec),
  ],
];
