import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';

String label(Tile tile) => '${tile.color}${tile.value}';

Future<GameProvider> pumpScreen(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final provider = GameProvider();
  provider.updateGameState(GameState(
    board: [
      TileSet(
        id: 's1',
        type: 'INVALID',
        tiles: [
          Tile(color: 'RED', value: 3),
          Tile(color: 'RED', value: 5),
        ],
      ),
    ],
    rack: [Tile(color: 'YELLOW', value: 9), Tile(color: 'BLACK', value: 2)],
  ));
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: provider,
    child: const MaterialApp(home: CorrectionScreen()),
  ));
  return provider;
}

/// Toggles one tile in the open picker.
Future<void> select(WidgetTester tester, String color, int value) async {
  await tester.tap(find.byKey(Key('color_$color')));
  await tester.pump();
  await tester.tap(find.byKey(Key('tile_${color}_$value')));
  await tester.pump();
}

Future<void> confirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('picker_add')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('+ on the rack opens the popover and appends the tiles',
      (tester) async {
    final provider = await pumpScreen(tester);

    await tester.tap(find.byTooltip('Add tiles to rack'));
    await tester.pumpAndSettle();
    expect(find.text('Quantity'), findsOneWidget);

    await tester.tap(find.byKey(const Key('quantity_plus')));
    await tester.pump();
    await select(tester, 'BLUE', 6);
    await confirm(tester);

    expect(provider.gameState.rack.map(label),
        ['YELLOW9', 'BLACK2', 'BLUE6', 'BLUE6']);
    expect(find.text('Quantity'), findsNothing);
  });

  testWidgets('selecting a tile alone adds nothing', (tester) async {
    final provider = await pumpScreen(tester);

    await tester.tap(find.byTooltip('Add tiles to rack'));
    await tester.pumpAndSettle();
    await select(tester, 'BLUE', 6);

    expect(provider.gameState.rack, hasLength(2));
    expect(find.text('Quantity'), findsOneWidget);
  });

  testWidgets('a batch of several colors is appended in selection order',
      (tester) async {
    final provider = await pumpScreen(tester);

    await tester.tap(find.byTooltip('Add tiles to rack'));
    await tester.pumpAndSettle();
    await select(tester, 'BLUE', 6);
    await select(tester, 'RED', 2);
    await select(tester, 'BLACK', 13);
    await confirm(tester);

    expect(provider.gameState.rack.map(label),
        ['YELLOW9', 'BLACK2', 'BLUE6', 'RED2', 'BLACK13']);
  });

  testWidgets('+ on a set appends the tile and keeps the set sorted',
      (tester) async {
    final provider = await pumpScreen(tester);

    await tester.tap(find.byTooltip('Add tiles to set'));
    await tester.pumpAndSettle();
    await select(tester, 'RED', 4);
    await confirm(tester);

    final set = provider.gameState.board.single;
    expect(set.tiles.map(label), ['RED3', 'RED4', 'RED5']);
    expect(set.type, 'RUN');
    expect(provider.gameState.rack, hasLength(2));
  });

  testWidgets('a batch added to a set lands sorted', (tester) async {
    final provider = await pumpScreen(tester);

    await tester.tap(find.byTooltip('Add tiles to set'));
    await tester.pumpAndSettle();
    await select(tester, 'RED', 7);
    await select(tester, 'RED', 4);
    await select(tester, 'RED', 6);
    await confirm(tester);

    final set = provider.gameState.board.single;
    expect(set.tiles.map(label), ['RED3', 'RED4', 'RED5', 'RED6', 'RED7']);
    expect(set.type, 'RUN');
  });

  testWidgets('a mixed batch keeps the set invalid but editable',
      (tester) async {
    final provider = await pumpScreen(tester);

    await tester.tap(find.byTooltip('Add tiles to set'));
    await tester.pumpAndSettle();
    await select(tester, 'YELLOW', 1);
    await select(tester, 'BLUE', 9);
    await confirm(tester);

    final set = provider.gameState.board.single;
    expect(set.tiles.map(label), ['BLUE9', 'RED3', 'RED5', 'YELLOW1']);
    expect(set.type, 'INVALID');
    await tester.pump();
    expect(find.byTooltip('Add tiles to set'), findsOneWidget);
  });
}
