import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';

void main() {
  Tile tile(String id, String color, int value) =>
      Tile(id: id, color: color, value: value);

  /// Board: [before] (valid run), [merged] (run + group touching), [after].
  GameProvider boardWithMergedSet() {
    final provider = GameProvider();
    provider.updateGameState(
      GameState(
        board: [
          TileSet(
            id: 'before',
            type: 'INVALID',
            tiles: [
              tile('b1', 'BLACK', 1),
              tile('b2', 'BLACK', 2),
              tile('b3', 'BLACK', 3),
            ],
          ),
          TileSet(
            id: 'merged',
            type: 'INVALID',
            tiles: [
              tile('r1', 'RED', 1),
              tile('r2', 'RED', 2),
              tile('r3', 'RED', 3),
              tile('u5', 'BLUE', 5),
              tile('k5', 'BLACK', 5),
              tile('y5', 'YELLOW', 5),
            ],
          ),
          TileSet(
            id: 'after',
            type: 'INVALID',
            tiles: [tile('x9', 'YELLOW', 9)],
          ),
        ],
        rack: const [],
      ),
    );
    return provider;
  }

  List<List<String>> boardIds(GameProvider provider) => [
        for (final set in provider.gameState.board)
          [for (final t in set.tiles) t.id],
      ];

  test('splitSet cuts before the index and keeps the set in place', () {
    final provider = boardWithMergedSet();
    provider.splitSet('merged', 3);

    expect(boardIds(provider), [
      ['b1', 'b2', 'b3'],
      ['r1', 'r2', 'r3'],
      ['u5', 'k5', 'y5'],
      ['x9'],
    ]);
    final board = provider.gameState.board;
    expect(board[1].id, 'merged');
    expect(board[1].type, 'RUN');
    expect(board[2].type, 'GROUP');
  });

  test('splitSet ignores cuts at either end', () {
    final provider = boardWithMergedSet();
    provider.splitSet('merged', 0);
    provider.splitSet('merged', 6);

    expect(provider.gameState.board, hasLength(3));
  });

  test('autoSplitSet cuts a set into valid sets', () {
    final provider = boardWithMergedSet();

    expect(provider.autoSplitSet('merged'), isTrue);
    expect(boardIds(provider), [
      ['b1', 'b2', 'b3'],
      ['r1', 'r2', 'r3'],
      ['u5', 'k5', 'y5'],
      ['x9'],
    ]);
    expect(
      provider.gameState.board.map((s) => s.type),
      ['RUN', 'RUN', 'GROUP', 'INVALID'],
    );
  });

  test('autoSplitSet leaves a set that cannot be cut', () {
    final provider = boardWithMergedSet();

    expect(provider.autoSplitSet('after'), isFalse);
    expect(provider.autoSplitSet('before'), isFalse);
    expect(provider.gameState.board, hasLength(3));
  });
}
