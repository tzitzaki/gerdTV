// New, because nothing owned it: with a remote (Shield), Up/Down must leave a text field for the next control, and the
// control must scroll into view. Flutter's text-editing shortcuts take the arrows inside a field, so before the fix the
// focus stayed in the server field and the rest of the setup form was unreachable.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/theme.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('Up/Down move between fields and scroll the target into view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final nodes = List.generate(4, (_) => FocusNode());
    addTearDown(() {
      for (final n in nodes) {
        n.dispose();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            Shortcuts(shortcuts: fieldDpadKeys, child: child!),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (final n in nodes.take(3))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 100),
                    child: TextField(focusNode: n),
                  ),
                FilledButton(
                  key: const Key('button'),
                  focusNode: nodes[3],
                  onPressed: () {},
                  child: const Text('Connect'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    nodes[0].requestFocus();
    await tester.pump();
    for (var i = 1; i < nodes.length; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(nodes[i].hasPrimaryFocus, isTrue, reason: 'step $i');
    }
    expect(find.byKey(const Key('button')).hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(nodes[2].hasPrimaryFocus, isTrue);
  });
}
