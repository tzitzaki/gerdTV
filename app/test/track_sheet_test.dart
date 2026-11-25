// New, because nothing owned the audio/subtitle choice: the button shows only when there is one (mpv's "auto" and
// "no" don't count), tracks are named by language, title and codec (or "Track n"), and a tap applies the track.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/player/track_prefs.dart';
import 'package:gerdtv/screens/track_sheet.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  final auto = AudioTrack.auto(), no = AudioTrack.no();
  const de = AudioTrack('1', null, 'ger', codec: 'aac');
  const en = AudioTrack('2', 'Commentary', 'eng', codec: 'ac3');
  const subEn = SubtitleTrack('3', null, 'eng');

  test('a choice is more than one audio track or any subtitle', () {
    for (final (audio, subs, want) in [
      ([auto, no, de], <SubtitleTrack>[], false),
      ([auto, no, de, en], <SubtitleTrack>[], true),
      ([auto, no, de], [SubtitleTrack.auto(), SubtitleTrack.no()], false),
      ([auto, no, de], [SubtitleTrack.no(), subEn], true),
    ]) {
      expect(
        hasTrackChoice(Tracks(audio: audio, subtitle: subs)),
        want,
        reason: '$audio $subs',
      );
    }
  });

  test('the wishes become mpv properties, and no wish resets them', () {
    for (final (audio, subtitle, alang, slang, sid) in [
      ('de', 'en', 'de,deu,ger', 'en,eng', 'auto'),
      ('', 'off', '', '', 'no'),
      (null, 'klingon', '', '', 'auto'),
    ]) {
      final o = {
        for (final o in trackOptions(audio: audio, subtitle: subtitle))
          o.name: o.value,
      };
      expect((o['alang'], o['slang'], o['sid']), (alang, slang, sid));
      expect((o['aid'], o['audio-delay'], o['sub-delay']), ('auto', '0', '0'));
    }
    expect(
      trackLanguages.keys.every(
        (l) => trackOptions(audio: l).first.value.length > 3,
      ),
      isTrue,
    );
    expect(
      subtitleLook(size: '200').style.fontSize,
      2 * subtitleLook().style.fontSize!,
    );
  });

  testWidgets('labels and picking', (tester) async {
    final picked = <String>[];
    final delays = TrackDelays();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showTrackSheet(
                context,
                tracks: Tracks(
                  audio: [auto, no, de, en, const AudioTrack('4', null, null)],
                  subtitle: [SubtitleTrack.no(), subEn],
                ),
                current: const Track(audio: de),
                onAudio: (a) => picked.add('audio ${a.id}'),
                onSubtitle: (s) => picked.add('subtitle ${s.id}'),
                onDelay: ({audioMs, subtitleMs}) async =>
                    picked.add('delay $audioMs $subtitleMs'),
                delays: delays,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    Future<void> open() async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.text('ger · aac'), findsOneWidget);
    expect(find.text('eng (Commentary) · ac3'), findsOneWidget);
    expect(find.text('Track 3'), findsOneWidget, reason: 'nothing named');
    expect(find.text('Off'), findsOneWidget);
    await tester.tap(find.byKey(const Key('track.audio.2')));
    await tester.pumpAndSettle();
    expect(find.text('Off'), findsNothing, reason: 'the sheet closed');
    await open();
    await tester.tap(find.byKey(const Key('track.subtitle.no')));
    await tester.pumpAndSettle();
    expect(picked, ['audio 2', 'subtitle no']);

    // A delay step applies at once and keeps the sheet open; reopened, the sheet shows it.
    picked.clear();
    await open();
    await tester.ensureVisible(find.byKey(const Key('delay.subtitle.less')));
    await tester.tap(find.byKey(const Key('delay.audio.more')));
    await tester.tap(find.byKey(const Key('delay.audio.more')));
    await tester.tap(find.byKey(const Key('delay.subtitle.less')));
    await tester.pump();
    expect(picked, ['delay 50 null', 'delay 100 null', 'delay null -50']);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await open();
    expect(find.text('100 ms'), findsOneWidget);
    expect(find.text('-50 ms'), findsOneWidget);
  });
}
