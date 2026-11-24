// New, because nothing owned the audio/subtitle choice: the button shows only when there is one (mpv's "auto" and
// "no" don't count), tracks are named by language, title and codec (or "Track n"), and a tap applies the track.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
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

  testWidgets('labels and picking', (tester) async {
    final picked = <String>[];
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
  });
}
