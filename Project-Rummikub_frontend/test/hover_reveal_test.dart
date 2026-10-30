import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/widgets/hover_reveal.dart';

void main() {
  late TestGesture mouse;
  final changes = <bool>[];

  Future<void> pumpRegion(
    WidgetTester tester, {
    bool enabled = true,
    bool opaque = true,
  }) async {
    changes.clear();
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    addTearDown(mouse.removePointer);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
            body: Center(
          child: SizedBox(
            width: 200,
            height: 100,
            child: HoverReveal(
              enabled: enabled,
              opaque: opaque,
              onRevealChanged: changes.add,
              builder: (context, revealed, close) => Column(
                children: [
                  Text(revealed ? 'revealed' : 'hidden'),
                  TextButton(
                    key: const ValueKey('inner'),
                    onPressed: close,
                    child: const Text('close'),
                  ),
                ],
              ),
            ),
          ),
        )),
      ),
    );
  }

  Offset center(WidgetTester tester) =>
      tester.getCenter(find.byType(SizedBox).last);

  testWidgets('hover reveals and leaving hides', (tester) async {
    await pumpRegion(tester);
    expect(find.text('hidden'), findsOneWidget);

    await mouse.moveTo(center(tester));
    await tester.pump();
    expect(find.text('revealed'), findsOneWidget);

    await mouse.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(find.text('hidden'), findsOneWidget);
    expect(changes, [true, false]);
  });

  testWidgets('a tap reveals for touch and a second tap hides', (tester) async {
    await pumpRegion(tester);
    final target =
        tester.getTopRight(find.byType(HoverReveal)) + const Offset(-10, 10);

    await tester.tapAt(target);
    await tester.pump();
    expect(find.text('revealed'), findsOneWidget);

    await tester.tapAt(target);
    await tester.pump();
    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('close() folds a tap-opened region', (tester) async {
    await pumpRegion(tester);
    final target =
        tester.getTopRight(find.byType(HoverReveal)) + const Offset(-10, 10);
    await tester.tapAt(target);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('inner')));
    await tester.pump();

    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('a mouse that is still over it keeps it open after close()',
      (tester) async {
    await pumpRegion(tester);
    await mouse.moveTo(center(tester));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('inner')));
    await tester.pump();

    // No exit event would ever re-open it, so it must stay open.
    expect(find.text('revealed'), findsOneWidget);
  });

  testWidgets('a click on desktop does not leave it stuck open',
      (tester) async {
    await pumpRegion(tester);
    final target =
        tester.getTopRight(find.byType(HoverReveal)) + const Offset(-10, 10);
    await mouse.moveTo(target);
    await mouse.down(target);
    await mouse.up();
    await tester.pump();
    expect(find.text('revealed'), findsOneWidget);

    await mouse.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('keyboard focus inside reveals it', (tester) async {
    await pumpRegion(tester);

    Focus.of(tester.element(find.text('close'))).requestFocus();
    await tester.pump();
    expect(find.text('revealed'), findsOneWidget);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('a disabled region never reveals', (tester) async {
    await pumpRegion(tester, enabled: false);

    await mouse.moveTo(center(tester));
    await tester.pump();
    await tester.tapAt(center(tester));
    await tester.pump();

    expect(find.text('hidden'), findsOneWidget);
    expect(changes, isEmpty);
  });

  testWidgets('disabling an open region hides it', (tester) async {
    await pumpRegion(tester);
    await mouse.moveTo(center(tester));
    await tester.pump();
    expect(find.text('revealed'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
            body: Center(
          child: SizedBox(
            width: 200,
            height: 100,
            child: HoverReveal(
              enabled: false,
              onRevealChanged: changes.add,
              builder: (context, revealed, close) =>
                  Text(revealed ? 'revealed' : 'hidden'),
            ),
          ),
        )),
      ),
    );
    await tester.pump();

    expect(find.text('hidden'), findsOneWidget);
    expect(changes.last, isFalse);
  });

  testWidgets('a non-opaque region lets the one behind it hover too',
      (tester) async {
    final behind = <bool>[];
    final front = <bool>[];
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    addTearDown(mouse.removePointer);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
            body: Center(
          child: SizedBox(
            width: 200,
            height: 100,
            child: Stack(
              children: [
                Positioned.fill(
                  child: HoverReveal(
                    onRevealChanged: behind.add,
                    builder: (context, revealed, close) => const SizedBox(),
                  ),
                ),
                Positioned.fill(
                  child: HoverReveal(
                    opaque: false,
                    onRevealChanged: front.add,
                    builder: (context, revealed, close) => const SizedBox(),
                  ),
                ),
              ],
            ),
          ),
        )),
      ),
    );

    await mouse.moveTo(const Offset(400, 300));
    await tester.pump();

    expect(front, [true]);
    expect(behind, [true]);
  });
}
