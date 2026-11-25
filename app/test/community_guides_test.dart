// New, because nothing owned the guide presets: every community guide is one distinct country file URL of the
// expected form, the sheet lists them by country and hands the picked one's URL on; added ones are listed by their
// short name, with the URL on tap.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/guide_settings.dart';
import 'package:material_ui/material_ui.dart';

const _share = 'https://epgshare01.online/epgshare01/epg_ripper_';

void main() {
  test('presets are distinct files; only Rytec is plain HTTP', () {
    final urls = [
      for (final p in guideProjects)
        for (final f in p.files) p.url(f),
    ];
    expect(urls.toSet().length, urls.length);
    for (final p in guideProjects) {
      for (final f in p.files) {
        expect(f, matches(RegExp(r'^\w+$')), reason: p.name);
        if (p.name != 'Rytec') expect(p.url(f), startsWith('https://'));
      }
    }
    expect(urls, contains('https://free-epg.de/api/epg/at.xml.gz'));
    expect(urls, contains('http://www.xmltvepg.nl/rytecDE_Basic.xz'));
    expect(urls, contains('${_share}BEIN1.xml.gz'));
    // The guide list names a community file by file and project and any other source by its URL.
    expect(guideSourceLabel('${_share}DE1.xml.gz'), 'DE · epgshare01');
    expect(guideSourceLabel('${_share}US2.xml.gz'), 'US 2 · epgshare01');
    expect(
      guideSourceLabel('https://free-epg.de/api/epg/at.xml.gz'),
      'AT · free-epg',
    );
    const own = 'https://example.invalid/guide.xml.gz';
    expect(guideSourceLabel(own), own);
  });

  testWidgets('a source row shows its URL on tap', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showGuideSourceUrl(context, '${_share}UK1.xml.gz'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('UK · epgshare01'), findsOneWidget);
    expect(find.text('${_share}UK1.xml.gz'), findsOneWidget);
    await tester.tap(find.byKey(const Key('guide.source.close')));
    await tester.pumpAndSettle();
    expect(find.text('UK · epgshare01'), findsNothing);
  });

  testWidgets('the sheet offers what is not added and hands the picked on', (
    tester,
  ) async {
    final picked = <String>[];
    var added = <String>{};
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  pickCommunityGuide(context, picked.add, added: added),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    const search = Key('guide.community.search');
    const de = Key('guide.community.epgshare01.DE1');
    Future<void> open(String query) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(search), query);
      await tester.pumpAndSettle();
    }

    await open('de epgshare');
    await tester.tap(find.byKey(de));
    await tester.pumpAndSettle();
    expect(picked, ['${_share}DE1.xml.gz']);
    // Added (or pasted by hand): not offered; its project's heading goes with the last match.
    added = {picked.single};
    await open('de epgshare');
    expect(find.byKey(de), findsNothing);
    expect(find.text('epgshare01'), findsNothing);
    expect(find.text('No more guides to add.'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    // Removed: offered again.
    added = {};
    await open('de epgshare');
    expect(find.byKey(de), findsOneWidget);
  });
}
