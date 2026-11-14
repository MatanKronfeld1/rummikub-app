import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';
import 'package:rummikub_assistant/widgets/rack_widget.dart';

Future<GameProvider> pumpScreen(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final provider = GameProvider();
  provider.updateGameState(GameState(
    board: [
      TileSet(id: 's1', type: 'INVALID', tiles: [
        Tile(color: 'RED', value: 3),
        Tile(color: 'RED', value: 4),
        Tile(color: 'RED', value: 5),
      ]),
      TileSet(id: 's2', type: 'INVALID', tiles: [
        Tile(color: 'BLUE', value: 7),
        Tile(color: 'RED', value: 7),
        Tile(color: 'BLACK', value: 7),
      ]),
    ],
    rack: [Tile(color: 'YELLOW', value: 9), Tile(color: 'BLACK', value: 2)],
  ));
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: provider,
    child: const MaterialApp(home: CorrectionScreen()),
  ));
  return provider;
}

void main() {
  testWidgets('the set delete icon removes only that set', (tester) async {
    final provider = await pumpScreen(tester);
    expect(find.byKey(const Key('set_delete')), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('set_delete')).first);
    await tester.pump();

    expect(provider.gameState.board.map((s) => s.id), ['s2']);
    expect(find.byKey(const Key('set_delete')), findsOneWidget);
    expect(provider.gameState.rack, hasLength(2));
  });

  testWidgets('the rack clear icon empties the rack but keeps the rack UI',
      (tester) async {
    final provider = await pumpScreen(tester);

    await tester.tap(find.byKey(const Key('rack_clear')));
    await tester.pump();

    expect(provider.gameState.rack, isEmpty);
    expect(provider.gameState.board, hasLength(2));
    expect(find.byType(RackWidget), findsOneWidget);
    expect(find.byKey(const Key('rack_tiles')), findsOneWidget);
    expect(find.text('0 tiles'), findsOneWidget);
    expect(find.byTooltip('Add tiles to rack'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const Key('rack_clear'))).onPressed,
      isNull,
    );
  });
}
