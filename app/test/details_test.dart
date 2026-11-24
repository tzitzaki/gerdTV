// New, because nothing owned the movie page: the facts line keeps what the panel knows in order, the page shows the
// details with Play and Trailer, and a panel without details (M3U, an error) still leaves title and Play. The
// trailer's HTML carries the id and mutes only the preview. The web view itself is a device check.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/details_screen.dart';
import 'package:gerdtv/screens/trailer.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:material_ui/material_ui.dart';

ItemDetails details({
  String plot = '',
  String genre = '',
  String release = '',
  int? secs,
  double? rating,
  String trailer = '',
}) => ItemDetails(
  plot: plot,
  genre: genre,
  cast: '',
  director: '',
  release: release,
  durationSecs: secs,
  rating: rating,
  backdrop: '',
  trailer: trailer,
);

class _Library implements Library {
  _Library(this.answer);
  final ItemDetails? answer;

  @override
  Future<ItemDetails> details({required String key}) async =>
      answer ?? (throw 'no panel');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const movie = ItemInfo(
  key: 'movie:1',
  kind: ItemKind.movie,
  name: 'A film',
  category: 'g',
  logo: '',
  archiveDays: 0,
  group: '',
);

void main() {
  test('facts: year, length, rating, genre — what there is', () {
    expect(
      detailsFacts(
        details(
          release: '2019-05-01',
          secs: 6720,
          rating: 7.44,
          genre: 'Drama',
        ),
      ),
      '2019 · 1 h 52 min · ★ 7.4 · Drama',
    );
    expect(detailsFacts(details(secs: 1500)), '25 min');
    expect(detailsFacts(details()), '');
  });

  test('the trailer page plays the id; only the preview is muted', () {
    expect(
      trailerHtml('abcDEF12_-x', muted: true),
      contains("videoId: 'abcDEF12_-x'"),
    );
    expect(trailerHtml('abcDEF12_-x', muted: true), contains('mute: 1'));
    expect(trailerHtml('abcDEF12_-x', muted: false), contains('mute: 0'));
    expect(
      trailerUrl('abcDEF12_-x'),
      'https://www.youtube.com/watch?v=abcDEF12_-x',
    );
  });

  for (final (name, answer, plot, trailer) in [
    (
      'with details',
      details(plot: 'Someone does something.', trailer: 'abcDEF12_-x'),
      true,
      true,
    ),
    ('without (M3U, an error)', null, false, false),
  ]) {
    testWidgets('the page $name', (tester) async {
      // Linux, as on the desktop build: no web view, so no muted preview after the delay (Flutter's tests stand
      // in for Android otherwise, where the preview would need a real web view).
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var played = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: MovieScreen(
            library: _Library(answer),
            movie: movie,
            onPlay: () async => played++,
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('A film'), findsOneWidget);
      expect(
        find.text('Someone does something.'),
        plot ? findsOneWidget : findsNothing,
      );
      expect(
        find.byKey(const Key('details.trailer')),
        trailer ? findsOneWidget : findsNothing,
      );
      await tester.tap(find.byKey(const Key('details.play')));
      expect(played, 1);
      await tester.pump(trailerPreviewDelay * 2);
      expect(find.byKey(const Key('details.preview')), findsNothing);
    });
  }
}
