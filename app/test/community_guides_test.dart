// New, because nothing owned the guide presets: every community guide is one distinct country file URL of the
// expected form, the sheet lists them by country and hands the picked one's URL on; added ones are listed by their
// short name, with the URL on tap.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/guide_settings.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('presets are distinct country files', () {
    expect(communityGuides.toSet().length, communityGuides.length);
    for (final code in communityGuides) {
      expect(code, matches(RegExp(r'^[A-Z]{2}[0-9]$')), reason: code);
      expect(
        communityGuideUrl(code),
        startsWith('https://'),
        reason: 'plain HTTP is for providers only',
      );
      expect(communityGuideUrl(code), endsWith('$code.xml.gz'));
    }
    expect(communityGuideLabel('DE1'), 'DE');
    expect(communityGuideLabel('IN2'), 'IN 2');
    // The guide list names a community file by its short name and any other source by its URL.
    expect(guideSourceLabel(communityGuideUrl('DE1')), 'DE');
    expect(guideSourceLabel(communityGuideUrl('US2')), 'US 2');
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
                  showGuideSourceUrl(context, communityGuideUrl('UK1')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('UK'), findsOneWidget);
    expect(find.text(communityGuideUrl('UK1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('guide.source.close')));
    await tester.pumpAndSettle();
    expect(find.text('UK'), findsNothing);
  });

  testWidgets('the sheet hands the picked file on', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickCommunityGuide(context, picked.add),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('guide.community.DE1')),
      200,
    );
    await tester.tap(find.byKey(const Key('guide.community.DE1')));
    await tester.pumpAndSettle();
    expect(picked, [communityGuideUrl('DE1')]);
    expect(find.byKey(const Key('guide.community.DE1')), findsNothing);
  });
}
