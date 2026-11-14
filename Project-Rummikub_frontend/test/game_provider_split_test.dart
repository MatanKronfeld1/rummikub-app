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

  test('splitting after tile i (index i + 1) keeps tile i on the left', () {
    final provider = boardWithMergedSet();
    // The UI's scissors on the first tile of `before`.
    provider.splitSet('before', 0 + 1);

    expect(boardIds(provider), [
      ['b1'],
      ['b2', 'b3'],
      ['r1', 'r2', 'r3', 'u5', 'k5', 'y5'],
      ['x9'],
    ]);
    final board = provider.gameState.board;
    expect(board[0].id, 'before');
    expect(board[1].id, isNot('before'));
    expect(board[1].type, 'INVALID');
  });

  group('mergeWithNextSet', () {
    GameProvider boardOf(List<TileSet> sets) =>
        GameProvider()..updateGameState(GameState(board: sets, rack: const []));

    TileSet set(String id, List<Tile> tiles) =>
        TileSet(id: id, type: 'INVALID', tiles: tiles);

    test('joins a set with the one below, sorted, and keeps the first id', () {
      final provider = boardOf([
        set('a', [tile('r3', 'RED', 3), tile('r1', 'RED', 1)]),
        set('b', [tile('r2', 'RED', 2), tile('r4', 'RED', 4)]),
        set('c', [tile('x9', 'YELLOW', 9)]),
      ]);

      provider.mergeWithNextSet('a');

      expect(boardIds(provider), [
        ['r1', 'r2', 'r3', 'r4'],
        ['x9'],
      ]);
      expect(provider.gameState.board.map((s) => s.id), ['a', 'c']);
      expect(provider.gameState.board.first.type, 'RUN');
    });

    test('an illegal result comes out INVALID', () {
      final provider = boardOf([
        set('a', [tile('r1', 'RED', 1), tile('r2', 'RED', 2)]),
        set('b', [tile('u9', 'BLUE', 9)]),
      ]);

      provider.mergeWithNextSet('a');

      expect(boardIds(provider), [
        ['u9', 'r1', 'r2'],
      ]);
      expect(provider.gameState.board.single.type, 'INVALID');
    });

    test('does nothing for the last set or an unknown id', () {
      final provider = boardOf([
        set('a', [tile('r1', 'RED', 1)]),
        set('b', [tile('r2', 'RED', 2)]),
      ]);

      provider.mergeWithNextSet('b');
      provider.mergeWithNextSet('nope');

      expect(boardIds(provider), [
        ['r1'],
        ['r2'],
      ]);
    });

    test('an empty set below is dropped and the first set is left as it was',
        () {
      final provider = boardOf([
        // Deliberately unsorted: merging with nothing must not reorder it.
        set('a', [tile('r3', 'RED', 3), tile('r1', 'RED', 1), tile('r2', 'RED', 2)]),
        set('b', const []),
      ]);

      provider.mergeWithNextSet('a');

      expect(boardIds(provider), [
        ['r3', 'r1', 'r2'],
      ]);
    });

    test('an empty first set takes the tiles of the one below', () {
      final provider = boardOf([
        set('a', const []),
        set('b', [tile('r3', 'RED', 3), tile('r1', 'RED', 1)]),
      ]);

      provider.mergeWithNextSet('a');

      expect(boardIds(provider), [
        ['r3', 'r1'],
      ]);
      expect(provider.gameState.board.single.id, 'a');
    });

    test('two empty sets leave a single empty set', () {
      final provider = boardOf([set('a', const []), set('b', const [])]);

      provider.mergeWithNextSet('a');

      expect(provider.gameState.board, hasLength(1));
      expect(provider.gameState.board.single.tiles, isEmpty);
      expect(provider.gameState.board.single.type, 'INVALID');
    });

    test('notifies listeners once', () {
      final provider = boardOf([
        set('a', [tile('r1', 'RED', 1)]),
        set('b', [tile('r2', 'RED', 2)]),
      ]);
      var notifications = 0;
      provider.addListener(() => notifications++);

      provider.mergeWithNextSet('a');

      expect(notifications, 1);
    });
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
