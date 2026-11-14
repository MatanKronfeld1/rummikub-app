import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/models/models.dart';

void main() {
  Tile tile(String id, int value) =>
      Tile(id: id, color: 'RED', value: value);

  GameProvider runWithRackEnds() {
    final provider = GameProvider();
    provider.updateGameState(
      GameState(
        board: [
          TileSet(
            id: 'run',
            type: 'RUN',
            tiles: [tile('4', 4), tile('5', 5), tile('6', 6)],
          ),
        ],
        rack: [tile('3', 3), tile('7', 7)],
      ),
    );
    return provider;
  }

  test('inserts to the left of the first tile', () {
    final provider = runWithRackEnds();
    provider.moveTile(
      tileId: '3',
      destination: TileDestination.insertIntoSet('run', 0),
    );
    expect(
      provider.gameState.board.single.tiles.map((t) => t.value),
      [3, 4, 5, 6],
    );
    expect(provider.gameState.board.single.type, 'RUN');
  });

  test('inserts to the right of the last tile', () {
    final provider = runWithRackEnds();
    provider.moveTile(
      tileId: '7',
      destination: TileDestination.insertIntoSet('run', 3),
    );
    expect(
      provider.gameState.board.single.tiles.map((t) => t.value),
      [4, 5, 6, 7],
    );
  });

  test('move-here (the end of the set) still lands the tile in order', () {
    final provider = runWithRackEnds();
    provider.moveTile(
      tileId: '3',
      destination: TileDestination.insertIntoSet('run', 3),
    );
    expect(
      provider.gameState.board.single.tiles.map((t) => t.value),
      [3, 4, 5, 6],
    );
    expect(provider.gameState.board.single.type, 'RUN');
    expect(provider.gameState.rack.map((t) => t.id), ['7']);
  });

  test('moving a tile within its own set leaves a sorted set sorted', () {
    final provider = runWithRackEnds();
    provider.moveTile(
      tileId: '4',
      fromSetId: 'run',
      destination: TileDestination.insertIntoSet('run', 3),
    );
    expect(
      provider.gameState.board.single.tiles.map((t) => t.value),
      [4, 5, 6],
    );
  });

  test('a set with a joker keeps the position the tile was dropped at', () {
    final provider = GameProvider();
    provider.updateGameState(
      GameState(
        board: [
          TileSet(
            id: 'jr',
            type: 'RUN',
            tiles: [
              tile('4', 4),
              Tile(id: 'j', color: 'JOKER', value: 0),
              tile('6', 6),
            ],
          ),
        ],
        rack: [tile('7', 7)],
      ),
    );
    provider.moveTile(
      tileId: '7',
      destination: TileDestination.insertIntoSet('jr', 0),
    );
    expect(
      provider.gameState.board.single.tiles.map((t) => t.id),
      ['7', '4', 'j', '6'],
    );
  });

  test('moves a tile from one set to the end of another', () {
    final provider = GameProvider();
    provider.updateGameState(
      GameState(
        board: [
          TileSet(
            id: 'a',
            type: 'RUN',
            tiles: [tile('1', 1), tile('2', 2), tile('3', 3), tile('4', 4)],
          ),
          TileSet(
            id: 'b',
            type: 'RUN',
            tiles: [tile('7', 7), tile('8', 8), tile('9', 9)],
          ),
        ],
        rack: const [],
      ),
    );
    provider.moveTile(
      tileId: '4',
      fromSetId: 'a',
      destination: TileDestination.insertIntoSet('b', 3),
    );
    expect(provider.gameState.board.map((s) => s.tiles.map((t) => t.id)), [
      ['1', '2', '3'],
      ['4', '7', '8', '9'],
    ]);
  });
}
