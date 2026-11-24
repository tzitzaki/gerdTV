// New, because nothing owned the guide presets: every community guide is one distinct country file URL of the
// expected form, the sheet lists them by country and hands the picked one's URL on.
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
