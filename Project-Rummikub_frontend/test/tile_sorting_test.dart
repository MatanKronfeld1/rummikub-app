import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/models/rummikub_tiles.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';

Tile t(String color, int value, [String? id]) =>
    Tile(id: id, color: color, value: value);

String label(Tile tile) => '${tile.color}${tile.value}';

void main() {
  group('sortTiles', () {
    test('orders by color Black, Blue, Red, Yellow, then value, jokers last', () {
      final sorted = sortTiles([
        t('JOKER', 0),
        t('YELLOW', 2),
        t('RED', 9),
        t('BLUE', 13),
        t('BLACK', 5),
        t('RED', 1),
        t('BLACK', 1),
      ]);
      expect(sorted.map(label), [
        'BLACK1',
        'BLACK5',
        'BLUE13',
        'RED1',
        'RED9',
        'YELLOW2',
        'JOKER0',
      ]);
    });

    test('does not modify the input list', () {
      final input = [t('RED', 5), t('RED', 1)];
      sortTiles(input);
      expect(input.map(label), ['RED5', 'RED1']);
    });
  });

  group('sortSetTiles', () {
    test('sorts a set without jokers', () {
      expect(
        sortSetTiles([t('RED', 5), t('RED', 3), t('RED', 4)]).map(label),
        ['RED3', 'RED4', 'RED5'],
      );
    });

    test('keeps the order of a set holding a joker', () {
      expect(
        sortSetTiles([t('RED', 3), t('JOKER', 0), t('RED', 5)]).map(label),
        ['RED3', 'JOKER0', 'RED5'],
      );
    });
  });

  group('GameProvider auto-sort', () {
    test('leaves the rack in detection order', () {
      final provider = GameProvider();
      provider.updateGameState(
        GameState(
          board: const [],
          rack: [t('YELLOW', 1), t('JOKER', 0), t('BLACK', 7), t('BLACK', 2)],
        ),
        fromVision: true,
      );
      expect(provider.gameState.rack.map(label),
          ['YELLOW1', 'JOKER0', 'BLACK7', 'BLACK2']);
    });

    test('a tile added, replaced or removed keeps its place on the rack', () {
      final provider = GameProvider();
      provider.updateRack([t('BLUE', 4, 'a'), t('RED', 8, 'b')]);

      provider.addTileToRack(t('BLACK', 12, 'c'));
      expect(provider.gameState.rack.map(label), ['BLUE4', 'RED8', 'BLACK12']);

      provider.replaceTile(
        provider.gameState.rack.firstWhere((x) => x.id == 'b'),
        t('BLACK', 1, 'b'),
      );
      expect(provider.gameState.rack.map(label), ['BLUE4', 'BLACK1', 'BLACK12']);

      provider.deleteTile(provider.gameState.rack.first);
      expect(provider.gameState.rack.map(label), ['BLACK1', 'BLACK12']);
    });

    test('sorts a set after a tile is edited or deleted', () {
      final provider = GameProvider();
      provider.updateBoard([
        TileSet(
          id: 's1',
          type: 'INVALID',
          tiles: [t('RED', 3, 'x'), t('RED', 4, 'y'), t('RED', 9, 'z')],
        ),
      ]);

      provider.replaceTile(
        provider.gameState.board.first.tiles.last,
        t('RED', 5, 'z'),
        setId: 's1',
      );
      expect(provider.gameState.board.first.tiles.map(label),
          ['RED3', 'RED4', 'RED5']);

      provider.replaceTile(
        provider.gameState.board.first.tiles.first,
        t('RED', 6, 'x'),
        setId: 's1',
      );
      expect(provider.gameState.board.first.tiles.map(label),
          ['RED4', 'RED5', 'RED6']);
      expect(provider.gameState.board.first.type, 'RUN');

      provider.deleteTile(provider.gameState.board.first.tiles.first,
          setId: 's1');
      expect(provider.gameState.board.first.tiles.map(label), ['RED5', 'RED6']);
    });

    test('sorts a set when it is updated with an added tile', () {
      final provider = GameProvider();
      final set = TileSet(
        id: 's1',
        type: 'INVALID',
        tiles: [t('BLUE', 7), t('BLUE', 9)],
      );
      provider.updateBoard([set]);
      provider.updateSetOnBoard(
        's1',
        set.copyWith(tiles: [...set.tiles, t('BLUE', 8)]),
      );
      expect(provider.gameState.board.first.tiles.map(label),
          ['BLUE7', 'BLUE8', 'BLUE9']);
    });
  });
}
