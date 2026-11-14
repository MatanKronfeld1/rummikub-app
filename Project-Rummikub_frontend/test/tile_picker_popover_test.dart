import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/widgets/tile_picker_popover.dart';

Future<List<List<Tile>>> pumpPopover(
  WidgetTester tester, {
  VoidCallback? onCancel,
}) async {
  final picks = <List<Tile>>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TilePickerPopover(
          onTilesSelected: picks.add,
          onCancel: onCancel,
        ),
      ),
    ),
  ));
  return picks;
}

/// Opens [color]'s numbers and toggles [value].
Future<void> toggle(WidgetTester tester, String color, int value) async {
  await tester.tap(find.byKey(Key('color_$color')));
  await tester.pump();
  await tester.tap(find.byKey(Key('tile_${color}_$value')));
  await tester.pump();
}

String label(Tile tile) => '${tile.color}${tile.value}';

void main() {
  testWidgets('selecting a color expands numbers 1-13', (tester) async {
    await pumpPopover(tester);
    expect(find.byKey(const Key('tile_RED_1')), findsNothing);

    await tester.tap(find.byKey(const Key('color_RED')));
    await tester.pump();

    for (var value = 1; value <= 13; value++) {
      expect(find.byKey(Key('tile_RED_$value')), findsOneWidget);
    }
    expect(find.byKey(const Key('tile_BLUE_1')), findsNothing);
  });

  testWidgets('hovering a color expands its numbers', (tester) async {
    await pumpPopover(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(find.byKey(const Key('color_BLUE'))));
    await tester.pump();

    expect(find.byKey(const Key('tile_BLUE_13')), findsOneWidget);
  });

  testWidgets('tapping a number only selects it', (tester) async {
    final picks = await pumpPopover(tester);

    await toggle(tester, 'YELLOW', 7);

    expect(picks, isEmpty);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byKey(const Key('picker_selected_badge')), findsOneWidget);
  });

  testWidgets('tapping a selected number again deselects it', (tester) async {
    final picks = await pumpPopover(tester);

    await toggle(tester, 'YELLOW', 7);
    await tester.tap(find.byKey(const Key('tile_YELLOW_7')));
    await tester.pump();

    expect(find.text('0 selected'), findsOneWidget);
    expect(find.byKey(const Key('picker_selected_badge')), findsNothing);
    expect(picks, isEmpty);
  });

  testWidgets('Add is disabled until something is selected', (tester) async {
    await pumpPopover(tester);
    FilledButton add() =>
        tester.widget<FilledButton>(find.byKey(const Key('picker_add')));

    expect(add().onPressed, isNull);
    await toggle(tester, 'RED', 1);
    expect(add().onPressed, isNotNull);
  });

  testWidgets('the selection survives switching colors; Add sends it once, in order',
      (tester) async {
    final picks = await pumpPopover(tester);

    await toggle(tester, 'RED', 5);
    await toggle(tester, 'RED', 6);
    await toggle(tester, 'RED', 7);
    await toggle(tester, 'BLUE', 9);
    await toggle(tester, 'BLACK', 9);
    expect(find.text('5 selected'), findsOneWidget);

    // Back on red, the earlier picks are still marked.
    await tester.tap(find.byKey(const Key('color_RED')));
    await tester.pump();
    expect(find.byKey(const Key('picker_selected_badge')), findsNWidgets(3));

    await tester.tap(find.byKey(const Key('picker_add')));

    expect(picks, hasLength(1));
    expect(picks.single.map(label),
        ['RED5', 'RED6', 'RED7', 'BLUE9', 'BLACK9']);
  });

  testWidgets('Clear empties the selection', (tester) async {
    await pumpPopover(tester);
    await toggle(tester, 'RED', 1);
    await toggle(tester, 'BLUE', 2);

    await tester.tap(find.byKey(const Key('picker_clear')));
    await tester.pump();

    expect(find.text('0 selected'), findsOneWidget);
  });

  testWidgets('Cancel shows only when asked for and adds nothing',
      (tester) async {
    await pumpPopover(tester);
    expect(find.byKey(const Key('picker_cancel')), findsNothing);

    var cancelled = 0;
    final picks = await pumpPopover(tester, onCancel: () => cancelled++);
    await toggle(tester, 'RED', 1);
    await tester.tap(find.byKey(const Key('picker_cancel')));

    expect(cancelled, 1);
    expect(picks, isEmpty);
  });

  testWidgets('quantity is the number of copies of each selected tile',
      (tester) async {
    final picks = await pumpPopover(tester);
    await toggle(tester, 'BLACK', 4);
    await toggle(tester, 'BLUE', 8);

    await tester.tap(find.byKey(const Key('quantity_plus')));
    await tester.pump();
    expect(find.widgetWithText(TextField, '2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('picker_add')));
    expect(picks.last.map(label), ['BLACK4', 'BLACK4', 'BLUE8', 'BLUE8']);
  });

  testWidgets('quantity stepper and field set the number of copies',
      (tester) async {
    final picks = await pumpPopover(tester);
    await toggle(tester, 'BLACK', 4);

    await tester.tap(find.byKey(const Key('quantity_plus')));
    await tester.tap(find.byKey(const Key('quantity_plus')));
    await tester.pump();
    expect(find.widgetWithText(TextField, '3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('picker_add')));
    expect(picks.last, hasLength(3));

    await tester.tap(find.byKey(const Key('quantity_minus')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('picker_add')));
    expect(picks.last, hasLength(2));

    await tester.enterText(find.byKey(const Key('quantity_field')), '5');
    await tester.pump();
    await tester.tap(find.byKey(const Key('picker_add')));
    expect(picks.last, hasLength(5));
  });

  testWidgets('quantity is clamped to 1..8', (tester) async {
    final picks = await pumpPopover(tester);
    await toggle(tester, 'BLACK', 4);

    await tester.tap(find.byKey(const Key('quantity_minus')));
    await tester.pump();
    expect(find.widgetWithText(TextField, '1'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('quantity_field')), '20');
    await tester.pump();
    await tester.tap(find.byKey(const Key('picker_add')));
    expect(picks.single, hasLength(8));
  });

  testWidgets('copies are distinct tiles with the same color and value',
      (tester) async {
    final picks = await pumpPopover(tester);
    await toggle(tester, 'RED', 9);
    await tester.enterText(find.byKey(const Key('quantity_field')), '2');
    await tester.pump();
    await tester.tap(find.byKey(const Key('picker_add')));

    final tiles = picks.single;
    expect(tiles.map(label), ['RED9', 'RED9']);
    expect(tiles[0].id, isNot(tiles[1].id));
  });

  testWidgets('joker shows black and red options that select one joker',
      (tester) async {
    final picks = await pumpPopover(tester);
    await tester.tap(find.byKey(const Key('color_JOKER')));
    await tester.pump();

    expect(find.byKey(const Key('joker_black')), findsOneWidget);
    expect(find.byKey(const Key('joker_red')), findsOneWidget);

    await tester.tap(find.byKey(const Key('joker_red')));
    await tester.pump();
    // The model has one joker, so both looks are marked.
    expect(find.byKey(const Key('picker_selected_badge')), findsNWidgets(2));
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('picker_add')));
    expect(picks.single.single.color, 'JOKER');
    expect(picks.single.single.value, 0);
  });

  testWidgets('the + button opens the popover; Add commits and closes it',
      (tester) async {
    final picks = <List<Tile>>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TilePickerButton(onTilesSelected: picks.add)),
    ));
    expect(find.byType(TilePickerPopover), findsNothing);

    await tester.tap(find.byKey(const Key('tile_picker_button')));
    await tester.pumpAndSettle();
    expect(find.byType(TilePickerPopover), findsOneWidget);

    await toggle(tester, 'BLUE', 2);
    // Selecting alone neither adds nor closes.
    expect(picks, isEmpty);
    expect(find.byType(TilePickerPopover), findsOneWidget);

    await tester.tap(find.byKey(const Key('picker_add')));
    await tester.pumpAndSettle();

    expect(picks.single.single.color, 'BLUE');
    expect(find.byType(TilePickerPopover), findsNothing);
  });

  testWidgets('Cancel in the dialog closes it without adding', (tester) async {
    final picks = <List<Tile>>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: TilePickerButton(onTilesSelected: picks.add)),
    ));

    await tester.tap(find.byKey(const Key('tile_picker_button')));
    await tester.pumpAndSettle();
    await toggle(tester, 'BLUE', 2);
    await tester.tap(find.byKey(const Key('picker_cancel')));
    await tester.pumpAndSettle();

    expect(picks, isEmpty);
    expect(find.byType(TilePickerPopover), findsNothing);
  });
}
