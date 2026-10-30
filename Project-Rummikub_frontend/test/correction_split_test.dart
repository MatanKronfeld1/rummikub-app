import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';
import 'package:rummikub_assistant/widgets/rummikub_tiles.dart';

void main() {
  Tile tile(String id, String color, int value) =>
      Tile(id: id, color: color, value: value);

  TileSet set(String type, List<Tile> tiles) =>
      TileSet(id: 'set', type: type, tiles: tiles);

  Future<void> pumpCard(
    WidgetTester tester,
    TileSet tileSet, {
    ValueChanged<int>? onSplitAt,
    VoidCallback? onAutoSplit,
    ValueChanged<int>? onInsertAt,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardSetCard(
            setIndex: 0,
            tileSet: tileSet,
            onSplitAt: onSplitAt,
            onAutoSplit: onAutoSplit,
            onInsertAt: onInsertAt,
          ),
        ),
      ),
    );
  }

  group('BoardSetCard split controls', () {
    final tiles = [
      tile('a', 'RED', 1),
      tile('b', 'BLUE', 9),
      tile('c', 'BLACK', 3),
    ];

    testWidgets('shows a scissors button between each pair of tiles',
        (tester) async {
      final cuts = <int>[];
      await pumpCard(tester, set('INVALID', tiles), onSplitAt: cuts.add);

      expect(find.byIcon(Icons.content_cut), findsNWidgets(2));
      await tester.tap(find.byIcon(Icons.content_cut).last);
      expect(cuts, [2]);
    });

    testWidgets('hides scissors while a tile is being placed', (tester) async {
      await pumpCard(
        tester,
        set('INVALID', tiles),
        onSplitAt: (_) {},
        onInsertAt: (_) {},
      );

      expect(find.byIcon(Icons.content_cut), findsNothing);
    });

    testWidgets('shows Auto-split only when given a callback', (tester) async {
      var pressed = 0;
      await pumpCard(tester, set('INVALID', tiles), onAutoSplit: () => pressed++);
      await tester.tap(find.text('Auto-split'));
      expect(pressed, 1);

      await pumpCard(tester, set('INVALID', tiles));
      expect(find.text('Auto-split'), findsNothing);
    });
  });

  group('CorrectionScreen split', () {
    Future<GameProvider> pumpScreen(WidgetTester tester, TileSet board) async {
      final provider = GameProvider()
        ..updateGameState(GameState(board: [board], rack: const []));
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: provider,
          child: const MaterialApp(home: CorrectionScreen()),
        ),
      );
      return provider;
    }

    testWidgets('one scissors tap splits an over-merged set', (tester) async {
      final provider = await pumpScreen(
        tester,
        set('INVALID', [
          tile('a', 'BLACK', 10),
          tile('b', 'BLUE', 12),
          tile('c', 'RED', 6),
          tile('d', 'RED', 13),
          tile('e', 'YELLOW', 9),
        ]),
      );

      expect(find.text('Auto-split'), findsNothing);
      await tester.tap(find.byIcon(Icons.content_cut).at(2));
      await tester.pump();

      expect(
        provider.gameState.board
            .map((s) => s.tiles.map((t) => t.id).toList())
            .toList(),
        [
          ['a', 'b', 'c'],
          ['d', 'e'],
        ],
      );
    });

    testWidgets('Auto-split cuts a run and group apart', (tester) async {
      final provider = await pumpScreen(
        tester,
        set('INVALID', [
          tile('r1', 'RED', 1),
          tile('r2', 'RED', 2),
          tile('r3', 'RED', 3),
          tile('u5', 'BLUE', 5),
          tile('k5', 'BLACK', 5),
          tile('y5', 'YELLOW', 5),
        ]),
      );

      await tester.tap(find.text('Auto-split'));
      await tester.pump();

      expect(
        provider.gameState.board.map((s) => s.type),
        ['RUN', 'GROUP'],
      );
      expect(find.byIcon(Icons.content_cut), findsNothing);
    });

    testWidgets('valid sets show no split controls', (tester) async {
      await pumpScreen(
        tester,
        set('RUN', [
          tile('r1', 'RED', 1),
          tile('r2', 'RED', 2),
          tile('r3', 'RED', 3),
        ]),
      );

      expect(find.byIcon(Icons.content_cut), findsNothing);
      expect(find.text('Auto-split'), findsNothing);
    });
  });
}
