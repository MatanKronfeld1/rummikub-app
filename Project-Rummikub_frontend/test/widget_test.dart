import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';

void main() {
  Future<GameProvider> pumpCorrection(
    WidgetTester tester,
    GameState state,
  ) async {
    final provider = GameProvider()..updateGameState(state, fromVision: true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: CorrectionScreen()),
      ),
    );
    return provider;
  }

  bool solveEnabled(WidgetTester tester) =>
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed !=
      null;

  testWidgets('vision correction blocks Solve while a set is invalid',
      (tester) async {
    await pumpCorrection(
      tester,
      GameState(
        board: [
          TileSet(type: 'INVALID', tiles: [Tile(color: 'RED', value: 1)]),
        ],
        rack: [
          Tile(color: 'BLUE', value: 7),
          Tile(color: 'JOKER', value: 0),
        ],
      ),
    );

    expect(find.text('Set 1  ·  INVALID'), findsOneWidget);
    expect(find.text('2 tiles'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('J'), findsOneWidget);
    expect(find.textContaining('at least 3 tiles'), findsOneWidget);
    expect(solveEnabled(tester), isFalse);
    // Normal runs carry no vision debug dump, so no export button.
    expect(find.text('Download JPEG + JSON for Roboflow'), findsNothing);
  });

  testWidgets('vision correction allows Solve once every set is legal',
      (tester) async {
    await pumpCorrection(
      tester,
      GameState(
        board: [
          TileSet(
            type: 'INVALID',
            tiles: [
              Tile(color: 'RED', value: 4),
              Tile(color: 'RED', value: 5),
              Tile(color: 'RED', value: 6),
            ],
          ),
        ],
        rack: [Tile(color: 'RED', value: 7)],
      ),
    );

    expect(find.text('Set 1  ·  RUN'), findsOneWidget);
    expect(solveEnabled(tester), isTrue);
  });
}
