import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';
import 'package:rummikub_assistant/widgets/rummikub_tiles.dart';

TestGesture? _mouse;

/// Moves one mouse pointer (added on first use, removed after the test) over
/// [target]; a second pointer per test would trip the mouse tracker.
Future<void> hover(WidgetTester tester, Finder target) async {
  var mouse = _mouse;
  if (mouse == null) {
    final added = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await added.addPointer(location: Offset.zero);
    addTearDown(() async {
      await added.removePointer();
      _mouse = null;
    });
    mouse = _mouse = added;
  }
  await mouse.moveTo(tester.getCenter(target));
  await tester.pump();
}

void main() {
  Tile tile(String id, String color, int value) =>
      Tile(id: id, color: color, value: value);

  TileSet set(String type, List<Tile> tiles) =>
      TileSet(id: 'set', type: type, tiles: tiles);

  Future<void> pumpCard(
    WidgetTester tester,
    TileSet tileSet, {
    ValueChanged<int>? onSplitAfter,
    VoidCallback? onAutoSplit,
    bool readOnly = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BoardSetCard(
            setIndex: 0,
            tileSet: tileSet,
            onSplitAfter: onSplitAfter,
            onAutoSplit: onAutoSplit,
            readOnly: readOnly,
          ),
        ),
      ),
    );
  }

  test('canSplitAfter allows every tile except the last', () {
    expect(canSplitAfter(0, 3), isTrue);
    expect(canSplitAfter(1, 3), isTrue);
    expect(canSplitAfter(2, 3), isFalse);
    // A single tile has nothing to move right.
    expect(canSplitAfter(0, 1), isFalse);
    expect(canSplitAfter(0, 0), isFalse);
  });

  group('BoardSetCard split controls', () {
    final tiles = [
      tile('a', 'RED', 1),
      tile('b', 'BLUE', 9),
      tile('c', 'BLACK', 3),
    ];

    testWidgets('no scissors sit between tiles', (tester) async {
      await pumpCard(tester, set('INVALID', tiles), onSplitAfter: (_) {});

      expect(find.byIcon(Icons.content_cut), findsNothing);
    });

    testWidgets('hovering a tile offers a cut after it', (tester) async {
      final cuts = <int>[];
      await pumpCard(tester, set('INVALID', tiles), onSplitAfter: cuts.add);

      await hover(tester, find.text('9'));
      expect(find.byKey(const Key('tile_split')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tile_split')));

      expect(cuts, [1]);
    });

    testWidgets('the first tile can split, the last cannot', (tester) async {
      final cuts = <int>[];
      await pumpCard(tester, set('INVALID', tiles), onSplitAfter: cuts.add);

      await hover(tester, find.text('1'));
      await tester.tap(find.byKey(const Key('tile_split')));
      expect(cuts, [0]);

      await hover(tester, find.text('3'));
      expect(find.byKey(const Key('tile_split')), findsNothing);
    });

    testWidgets('a one-tile set has no scissors', (tester) async {
      await pumpCard(
        tester,
        set('INVALID', [tile('a', 'RED', 1)]),
        onSplitAfter: (_) {},
      );

      await hover(tester, find.text('1'));
      expect(find.byKey(const Key('tile_split')), findsNothing);
    });

    testWidgets('read-only cards and cards without a callback have none',
        (tester) async {
      await pumpCard(tester, set('INVALID', tiles));
      await hover(tester, find.text('1'));
      expect(find.byKey(const Key('tile_split')), findsNothing);

      await pumpCard(
        tester,
        set('INVALID', tiles),
        onSplitAfter: (_) {},
        readOnly: true,
      );
      await hover(tester, find.text('1'));
      expect(find.byKey(const Key('tile_split')), findsNothing);
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

    List<List<String>> boardIds(GameProvider provider) => [
          for (final s in provider.gameState.board)
            [for (final t in s.tiles) t.id],
        ];

    testWidgets('✂ on a tile leaves it in the left set', (tester) async {
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
      await hover(tester, find.text('6'));
      await tester.tap(find.byKey(const Key('tile_split')));
      await tester.pump();

      expect(boardIds(provider), [
        ['a', 'b', 'c'],
        ['d', 'e'],
      ]);
    });

    testWidgets('valid sets can be split too', (tester) async {
      final provider = await pumpScreen(
        tester,
        set('RUN', [
          tile('r1', 'RED', 1),
          tile('r2', 'RED', 2),
          tile('r3', 'RED', 3),
          tile('r4', 'RED', 4),
        ]),
      );

      await hover(tester, find.text('2'));
      await tester.tap(find.byKey(const Key('tile_split')));
      await tester.pump();

      expect(boardIds(provider), [
        ['r1', 'r2'],
        ['r3', 'r4'],
      ]);
    });

    testWidgets('splitting clears the selection', (tester) async {
      final provider = await pumpScreen(
        tester,
        set('INVALID', [
          tile('a', 'RED', 1),
          tile('b', 'RED', 2),
          tile('c', 'RED', 3),
        ]),
      );

      // A selected tile shows its actions without hover.
      await tester.tap(find.text('2'));
      await tester.pump();
      expect(find.byKey(const Key('tile_edit')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tile_split')));
      await tester.pump();

      expect(boardIds(provider), [
        ['a', 'b'],
        ['c'],
      ]);
      expect(find.byKey(const Key('tile_edit')), findsNothing);
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
    });

    testWidgets('valid sets show no Auto-split', (tester) async {
      await pumpScreen(
        tester,
        set('RUN', [
          tile('r1', 'RED', 1),
          tile('r2', 'RED', 2),
          tile('r3', 'RED', 3),
        ]),
      );

      expect(find.text('Auto-split'), findsNothing);
    });
  });
}
