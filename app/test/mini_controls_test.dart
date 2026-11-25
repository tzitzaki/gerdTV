// New, because nothing owned picture mode's buttons: the desktop mini player shows only the picture until a tap, the
// mouse or Tab asks for Mute, Restore and Stop, and 3 s later only the picture again.
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/player_screen.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  final picture = find.byKey(const Key('player.picture'));
  final mute = find.byKey(const Key('player.mute'));
  late List<String> pressed;

  Future<void> show(WidgetTester tester) {
    pressed = [];
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: MiniControls(
            muted: false,
            onDrag: () => pressed.add('drag'),
            onMute: () => pressed.add('mute'),
            onRestore: () => pressed.add('restore'),
            onStop: () => pressed.add('stop'),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  void expectShown(bool shown, String when) => expect(
    mute.hitTestable(),
    shown ? findsOneWidget : findsNothing,
    reason: when,
  );

  testWidgets('a tap shows the buttons for 3 s, a second tap hides them', (
    tester,
  ) async {
    await show(tester);
    expectShown(false, 'at first');
    // Where a hidden button is, a click shows the buttons and presses nothing.
    await tester.tapAt(tester.getCenter(mute));
    await tester.pump(); // no double-tap wait
    expect(pressed, isEmpty);
    expectShown(true, 'after a tap');
    await tester.pump(const Duration(seconds: 2));
    for (final b in ['mute', 'restore', 'miniStop']) {
      await tester.tap(find.byKey(Key('player.$b')));
    }
    expect(pressed, ['mute', 'restore', 'stop']);
    await tester.pump(const Duration(seconds: 2));
    expectShown(true, 'Mute restarted the 3 s');
    await tester.pump(const Duration(seconds: 2));
    expectShown(false, 'after 3 s');

    await tester.tap(picture);
    await tester.pump();
    expectShown(true, 'a new tap');
    await tester.tap(picture);
    await tester.pump();
    expectShown(false, 'the second tap');
    await tester.drag(picture, const Offset(60, 60));
    expect(pressed.last, 'drag');
  });

  testWidgets('the mouse shows them, its click keeps them, the next hides', (
    tester,
  ) async {
    await show(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(-10, -10));
    Future<void> move(Offset to) async {
      await mouse.moveTo(to);
      await tester.pump();
    }

    Future<void> click() async {
      await mouse.down(const Offset(200, 200));
      await mouse.up();
      await tester.pump();
    }

    await move(const Offset(200, 200));
    expectShown(true, 'on hover');
    await click();
    expectShown(true, 'the click after the move');
    await click();
    expectShown(false, 'the second click');
    await move(const Offset(205, 205));
    expectShown(false, 'still over the picture it was hidden on');
    await move(const Offset(-10, -10));
    await move(const Offset(200, 200));
    expectShown(true, 'back again');
    await tester.pump(const Duration(seconds: 3));
    expectShown(false, 'resting for 3 s');
  });

  testWidgets('Tab shows them while one has the focus, Enter presses it', (
    tester,
  ) async {
    await show(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expectShown(true, 'focused');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pressed, ['mute']);
    await tester.pump(const Duration(seconds: 4)); // Mute's timer
  });
}
