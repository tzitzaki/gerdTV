// New, because nothing owned it: with a remote, play/pause and Stop are visible side by side and reachable by D-pad
// (media_kit's own bar only opens with a tap); with touch they stay out of the picture.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/player_screen.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('play/pause and Stop by remote, hidden for touch', (
    tester,
  ) async {
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    final pressed = <String>[];
    Future<void> show({required bool active}) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: DpadControls(
            paused: false,
            onPause: () => pressed.add('pause'),
            onStop: () => pressed.add('stop'),
            onLeave: active ? () => pressed.add('leave') : null,
          ),
        ),
      ),
    );
    await show(active: false);
    await show(active: true); // OK: play/pause takes the focus
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.arrowUp,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
    expect(pressed, ['pause', 'stop', 'leave']);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    await tester.pump();
    expect(find.byKey(const Key('player.dpad.stop')), findsNothing);
  });
}
