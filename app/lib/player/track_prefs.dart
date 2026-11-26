// The profile's audio and subtitle wishes (Settings → Playback) as mpv properties, and the subtitles' look.
// One mpv plays everything and keeps its properties, so all of them are set at every start, also back to the default:
// a track picked by hand or a delay set for one item must not follow into the next. (A watchdog reload is no start:
// it keeps them.) Text subtitles are drawn by media_kit's SubtitleView (its libass is off), so their size and
// background are Flutter's, not mpv's sub-scale; picture subtitles (DVB, PGS) keep the stream's look.
// Apple's player picks its own tracks (the device's language); only these properties of mpv are set here.

import 'package:flutter/painting.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../src/rust/api/playback.dart';

const settingAudioLanguage = 'audio_language';
const settingSubtitleLanguage = 'subtitle_language';
const settingSubtitleSize = 'subtitle_size';
const settingSubtitleBackground = 'subtitle_background';

/// The subtitle choice that switches them off.
const subtitlesOff = 'off';

/// The offered languages: ISO 639-1 code → its name in itself. Streams name them by two or three letters.
const trackLanguages = {
  'de': 'Deutsch',
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'it': 'Italiano',
  'nl': 'Nederlands',
  'pl': 'Polski',
  'pt': 'Português',
  'tr': 'Türkçe',
};

const _threeLetters = {
  'de': 'deu,ger',
  'en': 'eng',
  'es': 'spa',
  'fr': 'fra,fre',
  'it': 'ita',
  'nl': 'nld,dut',
  'pl': 'pol',
  'pt': 'por',
  'tr': 'tur',
};

String _languages(String? code) =>
    _threeLetters.containsKey(code) ? '$code,${_threeLetters[code]}' : '';

/// What mpv gets before each start; null or an unknown language means mpv's own choice.
List<MpvOption> trackOptions({String? audio, String? subtitle}) => [
  MpvOption(name: 'alang', value: _languages(audio)),
  MpvOption(name: 'slang', value: _languages(subtitle)),
  const MpvOption(name: 'aid', value: 'auto'),
  MpvOption(name: 'sid', value: subtitle == subtitlesOff ? 'no' : 'auto'),
  const MpvOption(name: 'audio-delay', value: '0'),
  const MpvOption(name: 'sub-delay', value: '0'),
];

/// Subtitle sizes in percent of media_kit's default.
const subtitleSizes = [75, 100, 125, 150, 200];

SubtitleViewConfiguration subtitleLook({String? size, String? background}) {
  const base = SubtitleViewConfiguration();
  final percent = int.tryParse(size ?? '');
  return SubtitleViewConfiguration(
    style: base.style.copyWith(
      fontSize:
          base.style.fontSize! *
          (subtitleSizes.contains(percent) ? percent! : 100) /
          100,
      backgroundColor: background == '0'
          ? const Color(0x00000000)
          : base.style.backgroundColor,
      // Without the plate an outline-like shadow keeps white text readable on white pictures.
      shadows: background == '0'
          ? const [Shadow(blurRadius: 6), Shadow(blurRadius: 3)]
          : null,
    ),
  );
}

/// The delays of what plays, in milliseconds.
class TrackDelays {
  int audio = 0;
  int subtitle = 0;
}
