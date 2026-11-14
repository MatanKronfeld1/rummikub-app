import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/widgets/rack_widget.dart';
import 'package:rummikub_assistant/widgets/tile_widget.dart';

String label(Tile tile) => '${tile.color}${tile.value}';

Future<void> hover(WidgetTester tester, Finder target) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump();
}

Future<GameProvider> pumpRack(WidgetTester tester) async {
  final provider = GameProvider();
  provider.updateRack([
    Tile(id: 'a', color: 'BLUE', value: 4),
    Tile(id: 'b', color: 'RED', value: 8),
  ]);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: provider,
    child: MaterialApp(
      home: Scaffold(
        body: Consumer<GameProvider>(
          builder: (context, game, _) => RackWidget(
            tiles: game.gameState.rack,
            onTilesAdded: (_) {},
            onTileEdited: game.replaceTile,
            onTileDeleted: game.deleteTile,
          ),
        ),
      ),
    ),
  ));
  return provider;
}

void main() {
  testWidgets('actions appear only while hovering the tile', (tester) async {
    await pumpRack(tester);
    expect(find.byKey(const Key('tile_edit')), findsNothing);

    await hover(tester, find.text('4'));

    expect(find.byKey(const Key('tile_edit')), findsOneWidget);
    expect(find.byKey(const Key('tile_delete')), findsOneWidget);
    // Rack tiles are not in a set, so they cannot cut one.
    expect(find.byKey(const Key('tile_split')), findsNothing);
  });

  testWidgets('hovering shows Edit, Delete and Split together', (tester) async {
    var splits = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TileWidget(
          tile: Tile(color: 'RED', value: 1),
          onEdit: (_) {},
          onDelete: () {},
          onSplit: () => splits++,
        ),
      ),
    ));
    expect(find.byKey(const Key('tile_split')), findsNothing);

    await hover(tester, find.text('1'));

    expect(find.byKey(const Key('tile_edit')), findsOneWidget);
    expect(find.byKey(const Key('tile_delete')), findsOneWidget);
    expect(find.byKey(const Key('tile_split')), findsOneWidget);
    expect(find.byIcon(Icons.content_cut), findsOneWidget);
    expect(find.byTooltip('Split set here'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tile_split')));
    expect(splits, 1);
  });

  testWidgets('each action shows only when its callback is given',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TileWidget(
          tile: Tile(color: 'RED', value: 1),
          onSplit: () {},
        ),
      ),
    ));
    await hover(tester, find.text('1'));

    expect(find.byKey(const Key('tile_split')), findsOneWidget);
    expect(find.byKey(const Key('tile_edit')), findsNothing);
    expect(find.byKey(const Key('tile_delete')), findsNothing);
  });

  testWidgets('a selected tile shows its actions without hover',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TileWidget(
          tile: Tile(color: 'RED', value: 1),
          selected: true,
          onEdit: (_) {},
          onDelete: () {},
          onSplit: () {},
        ),
      ),
    ));
    expect(find.byKey(const Key('tile_edit')), findsOneWidget);
    expect(find.byKey(const Key('tile_split')), findsOneWidget);
  });

  testWidgets('a tile without callbacks has no actions', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TileWidget(tile: Tile(color: 'RED', value: 1), selected: true),
      ),
    ));
    expect(find.byKey(const Key('tile_edit')), findsNothing);
    expect(find.byKey(const Key('tile_delete')), findsNothing);
    expect(find.byKey(const Key('tile_split')), findsNothing);
  });

  testWidgets('Delete removes that tile only', (tester) async {
    final provider = await pumpRack(tester);

    await hover(tester, find.text('4'));
    await tester.tap(find.byKey(const Key('tile_delete')));
    await tester.pump();

    expect(provider.gameState.rack.map(label), ['RED8']);
    expect(find.text('4'), findsNothing);
  });

  testWidgets('Edit changes the tile in place and the rack keeps its order',
      (tester) async {
    final provider = await pumpRack(tester);
    expect(provider.gameState.rack.map(label), ['BLUE4', 'RED8']);

    await hover(tester, find.text('8'));
    await tester.tap(find.byKey(const Key('tile_edit')));
    await tester.pumpAndSettle();
    expect(find.text('Edit tile'), findsOneWidget);

    await tester
        .tap(find.widgetWithText(DropdownButtonFormField<String>, 'RED'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BLACK').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, '8'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('11').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(provider.gameState.rack.map(label), ['BLUE4', 'BLACK11']);
    expect(provider.gameState.rack.any((t) => t.id == 'b'), isTrue);
  });

  testWidgets('Cancel in the edit dialog leaves the tile unchanged',
      (tester) async {
    final provider = await pumpRack(tester);

    await hover(tester, find.text('4'));
    await tester.tap(find.byKey(const Key('tile_edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(provider.gameState.rack.map(label), ['BLUE4', 'RED8']);
  });
}
