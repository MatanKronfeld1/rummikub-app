import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/logic/set_validator.dart';
import 'package:rummikub_assistant/models/models.dart';

void main() {
  TileSet setOf(String type, List<Tile> tiles) =>
      TileSet(type: type, tiles: tiles);

  test('valid run is classified RUN', () {
    final classified = SetValidator.classifySet(
      setOf('INVALID', [
        Tile(color: 'RED', value: 1),
        Tile(color: 'RED', value: 2),
        Tile(color: 'RED', value: 3),
      ]),
    );
    expect(classified.type, 'RUN');
    expect(SetValidator.isBoardValid([classified]), isTrue);
  });

  test('valid group is classified GROUP', () {
    final classified = SetValidator.classifySet(
      setOf('INVALID', [
        Tile(color: 'RED', value: 5),
        Tile(color: 'BLUE', value: 5),
        Tile(color: 'BLACK', value: 5),
      ]),
    );
    expect(classified.type, 'GROUP');
  });

  test('short set is invalid', () {
    final classified = SetValidator.classifySet(
      setOf('RUN', [
        Tile(color: 'RED', value: 1),
        Tile(color: 'RED', value: 2),
      ]),
    );
    expect(classified.type, 'INVALID');
    expect(SetValidator.isBoardValid([classified]), isFalse);
  });

  test('empty board is valid', () {
    expect(SetValidator.isBoardValid([]), isTrue);
  });

  group('splitIntoValidSets', () {
    List<Tile> tiles(List<String> names) => [
          for (final name in names)
            Tile(
              color: name.replaceAll(RegExp(r'\d+$'), ''),
              value: int.parse(name.replaceAll(RegExp(r'^\D+'), '')),
            ),
        ];
    List<List<String>>? names(List<List<Tile>>? pieces) => pieces
        ?.map((p) => p.map((t) => '${t.color}${t.value}').toList())
        .toList();

    test('cuts a touching run and group apart', () {
      expect(
        names(SetValidator.splitIntoValidSets(
          tiles(['RED1', 'RED2', 'RED3', 'BLUE5', 'BLACK5', 'YELLOW5']),
        )),
        [
          ['RED1', 'RED2', 'RED3'],
          ['BLUE5', 'BLACK5', 'YELLOW5'],
        ],
      );
    });

    test('keeps a valid set whole', () {
      expect(
        SetValidator.splitIntoValidSets(tiles(['RED4', 'RED5', 'RED6', 'RED7']))
            ?.length,
        1,
      );
    });

    test('returns a descending piece in ascending order', () {
      expect(
        names(SetValidator.splitIntoValidSets(
          tiles(['BLUE9', 'BLUE8', 'BLUE7', 'RED2', 'BLACK2', 'YELLOW2']),
        )),
        [
          ['BLUE7', 'BLUE8', 'BLUE9'],
          ['RED2', 'BLACK2', 'YELLOW2'],
        ],
      );
    });

    test('returns null when no cut gives valid sets', () {
      expect(
        SetValidator.splitIntoValidSets(
          tiles(['BLACK10', 'BLUE12', 'BLUE12', 'RED6', 'RED13', 'RED9']),
        ),
        isNull,
      );
      expect(SetValidator.splitIntoValidSets(const []), isNull);
    });
  });
}
