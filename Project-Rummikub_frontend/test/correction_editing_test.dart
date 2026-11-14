import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';
import 'package:rummikub_assistant/widgets/rummikub_tiles.dart';

Tile tile(String id, String color, int value) =>
    Tile(id: id, color: color, value: value);

Future<GameProvider> pumpScreen(
  WidgetTester tester, {
  List<TileSet> board = const [],
  List<Tile> rack = const [],
}) async {
  tester.view.physicalSize = const Size(1600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final provider = GameProvider()
    ..updateGameState(GameState(board: board, rack: rack));
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: provider,
      child: const MaterialApp(home: CorrectionScreen()),
    ),
  );
  return provider;
}

List<List<String>> boardIds(GameProvider provider) => [
      for (final set in provider.gameState.board)
        [for (final t in set.tiles) t.id],
    ];

void main() {
  final run = TileSet(
    id: 'run',
    type: 'RUN',
    tiles: [
      tile('r4', 'RED', 4),
      tile('r5', 'RED', 5),
      tile('r6', 'RED', 6),
    ],
  );

  group('no + slots inside sets', () {
    Finder slotsInSets() => find.descendant(
          of: find.byType(BoardSetCard),
          matching: find.text('+'),
        );

    testWidgets('with nothing selected', (tester) async {
      await pumpScreen(tester, board: [run], rack: [tile('r3', 'RED', 3)]);

      expect(find.byType(BoardSetCard), findsOneWidget);
      expect(slotsInSets(), findsNothing);
    });

    testWidgets('with a tile selected', (tester) async {
      await pumpScreen(tester, board: [run], rack: [tile('r3', 'RED', 3)]);

      await tester.tap(find.text('3'));
      await tester.pump();

      expect(slotsInSets(), findsNothing);
      expect(find.byType(EmptySlot), findsOneWidget); // the Rack slot only
    });

    testWidgets('selecting a set tile shows only its hover actions',
        (tester) async {
      await pumpScreen(tester, board: [run]);

      await tester.tap(find.text('5'));
      await tester.pump();

      expect(slotsInSets(), findsNothing);
      expect(find.byKey(const Key('tile_edit')), findsOneWidget);
      expect(find.byKey(const Key('tile_delete')), findsOneWidget);
      expect(find.byKey(const Key('tile_split')), findsOneWidget);
    });
  });

  group('New set button', () {
    testWidgets('adds an empty set at the end without a selection',
        (tester) async {
      final provider = await pumpScreen(tester, board: [run]);
      expect(find.text('New set'), findsNothing); // the old drop zone is gone

      await tester.tap(find.byKey(const Key('add_set')));
      await tester.pump();

      final board = provider.gameState.board;
      expect(board, hasLength(2));
      expect(board.last.tiles, isEmpty);
      expect(board.last.type, 'INVALID');
      expect(find.text('Set 2  ·  INVALID'), findsOneWidget);
    });

    testWidgets('works on an empty board and can add several', (tester) async {
      final provider = await pumpScreen(tester);

      await tester.tap(find.byKey(const Key('add_set')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('add_set')));
      await tester.pump();

      expect(provider.gameState.board, hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty set can be filled with the picker or deleted',
        (tester) async {
      final provider = await pumpScreen(tester);
      await tester.tap(find.byKey(const Key('add_set')));
      await tester.pump();

      await tester.tap(find.byTooltip('Add tiles to set'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('color_BLUE')));
      await tester.pump();
      for (final value in [1, 2, 3]) {
        await tester.tap(find.byKey(Key('tile_BLUE_$value')));
      }
      await tester.pump();
      await tester.tap(find.byKey(const Key('picker_add')));
      await tester.pumpAndSettle();

      expect(provider.gameState.board.single.tiles, hasLength(3));
      expect(provider.gameState.board.single.type, 'RUN');

      await tester.tap(find.byKey(const Key('add_set')));
      await tester.pump();
      expect(provider.gameState.board, hasLength(2));
      await tester.tap(find.byKey(const Key('set_delete')).last);
      await tester.pump();
      expect(provider.gameState.board, hasLength(1));
    });

    testWidgets('an empty set blocks Solve until it is filled or deleted',
        (tester) async {
      await pumpScreen(tester, board: [run]);
      await tester.tap(find.byKey(const Key('add_set')));
      await tester.pump();

      final solve = find.widgetWithText(FloatingActionButton, 'Solve');
      expect(tester.widget<FloatingActionButton>(solve).onPressed, isNull);
      expect(find.textContaining('at least 3 tiles'), findsOneWidget);
    });
  });

  group('Unite button', () {
    final a = TileSet(
      id: 'a',
      type: 'INVALID',
      tiles: [tile('r3', 'RED', 3), tile('r1', 'RED', 1)],
    );
    final b = TileSet(
      id: 'b',
      type: 'INVALID',
      tiles: [tile('r2', 'RED', 2), tile('r4', 'RED', 4)],
    );
    final c = TileSet(id: 'c', type: 'INVALID', tiles: [tile('x9', 'BLUE', 9)]);

    testWidgets('shows under every set but the last', (tester) async {
      await pumpScreen(tester, board: [a, b, c]);

      expect(find.byKey(const Key('set_unite')), findsNWidgets(2));
      expect(find.byTooltip('Unite with set below'), findsNWidgets(2));
      // Neither the last card nor a lone set has one.
      expect(
        find.descendant(
          of: find.byType(BoardSetCard).last,
          matching: find.byKey(const Key('set_unite')),
        ),
        findsNothing,
      );
    });

    testWidgets('a lone set has no unite button', (tester) async {
      await pumpScreen(tester, board: [run]);

      expect(find.byKey(const Key('set_unite')), findsNothing);
    });

    testWidgets('joins a set with the one below and leaves the rest alone',
        (tester) async {
      final provider = await pumpScreen(tester, board: [a, b, c]);

      await tester.tap(find.byKey(const Key('set_unite')).first);
      await tester.pump();

      expect(boardIds(provider), [
        ['r1', 'r2', 'r3', 'r4'],
        ['x9'],
      ]);
      expect(provider.gameState.board.first.id, 'a');
      expect(provider.gameState.board.first.type, 'RUN');
      expect(find.byKey(const Key('set_unite')), findsOneWidget);
    });

    testWidgets('clears the tile selection', (tester) async {
      await pumpScreen(tester, board: [a, b], rack: [tile('k8', 'BLACK', 8)]);
      await tester.tap(find.text('8'));
      await tester.pump();
      expect(find.byKey(const Key('set_move_here')), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('set_unite')));
      await tester.pump();

      expect(find.byKey(const Key('set_move_here')), findsNothing);
    });
  });

  group('tap-to-move', () {
    testWidgets('move-here shows only while a tile is selected, once per set',
        (tester) async {
      final other = TileSet(
        id: 'other',
        type: 'GROUP',
        tiles: [
          tile('b7', 'BLUE', 7),
          tile('k7', 'BLACK', 7),
          tile('y7', 'YELLOW', 7),
        ],
      );
      await pumpScreen(tester, board: [run, other], rack: [tile('r3', 'RED', 3)]);
      expect(find.byKey(const Key('set_move_here')), findsNothing);

      await tester.tap(find.text('3'));
      await tester.pump();

      expect(find.byKey(const Key('set_move_here')), findsNWidgets(2));
      expect(find.byTooltip('Move selected tile here'), findsNWidgets(2));
    });

    testWidgets('moves a rack tile into a set, in order, and clears selection',
        (tester) async {
      final provider =
          await pumpScreen(tester, board: [run], rack: [tile('r3', 'RED', 3)]);

      await tester.tap(find.text('3'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('set_move_here')));
      await tester.pump();

      expect(boardIds(provider), [
        ['r3', 'r4', 'r5', 'r6'],
      ]);
      expect(provider.gameState.board.single.type, 'RUN');
      expect(provider.gameState.rack, isEmpty);
      expect(find.byKey(const Key('set_move_here')), findsNothing);
    });

    testWidgets('moves a tile from one set to another', (tester) async {
      final other = TileSet(
        id: 'other',
        type: 'INVALID',
        tiles: [tile('b1', 'BLUE', 1), tile('b2', 'BLUE', 2)],
      );
      final provider = await pumpScreen(tester, board: [run, other]);

      await tester.tap(find.text('6'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('set_move_here')).last);
      await tester.pump();

      expect(boardIds(provider), [
        ['r4', 'r5'],
        ['b1', 'b2', 'r6'],
      ]);
    });

    testWidgets('a set tile can go back to the rack through the Rack slot',
        (tester) async {
      final provider = await pumpScreen(tester, board: [run]);

      await tester.tap(find.text('6'));
      await tester.pump();
      await tester.tap(find.widgetWithText(EmptySlot, 'Rack'));
      await tester.pump();

      expect(provider.gameState.rack.map((t) => t.id), ['r6']);
      expect(boardIds(provider), [
        ['r4', 'r5'],
      ]);
    });

    testWidgets('tapping a tile never opens Edit; a second tap deselects',
        (tester) async {
      await pumpScreen(tester, board: [run], rack: [tile('r3', 'RED', 3)]);

      for (final value in ['5', '3']) {
        await tester.tap(find.text(value));
        await tester.pumpAndSettle();
        expect(find.text('Edit tile'), findsNothing);
        expect(find.byKey(const Key('tile_edit')), findsOneWidget);

        await tester.tap(find.text(value));
        await tester.pumpAndSettle();
        expect(find.text('Edit tile'), findsNothing);
        expect(find.byKey(const Key('tile_edit')), findsNothing);
        expect(find.byKey(const Key('set_move_here')), findsNothing);
      }
    });

    testWidgets('the tile\'s Edit button still opens the dialog',
        (tester) async {
      await pumpScreen(tester, board: [run]);

      await tester.tap(find.text('5'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tile_edit')));
      await tester.pumpAndSettle();

      expect(find.text('Edit tile'), findsOneWidget);
    });

    testWidgets('a tile moved back to the rack goes to the end, unsorted',
        (tester) async {
      final provider = await pumpScreen(
        tester,
        board: [run],
        rack: [tile('y9', 'YELLOW', 9), tile('k2', 'BLACK', 2)],
      );

      await tester.tap(find.text('6'));
      await tester.pump();
      await tester.tap(find.widgetWithText(EmptySlot, 'Rack'));
      await tester.pump();

      expect(provider.gameState.rack.map((t) => t.id), ['y9', 'k2', 'r6']);
    });

    testWidgets('the hint describes the new controls', (tester) async {
      await pumpScreen(tester, board: [run]);
      expect(find.textContaining('+ to the left'), findsNothing);
      expect(find.textContaining('between tiles'), findsNothing);
      expect(find.textContaining('move icon'), findsOneWidget);

      await tester.tap(find.text('5'));
      await tester.pump();
      expect(find.textContaining('+ to the left'), findsNothing);
      expect(find.textContaining('move icon'), findsOneWidget);
    });
  });
}
