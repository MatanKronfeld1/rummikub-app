import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/services/vision_parser.dart';

void main() {
  group('VisionParser.parseLabel', () {
    test('maps ColorNumber classes onto app colors', () {
      expect(VisionParser.parseLabel('Red7'), ('RED', 7));
      expect(VisionParser.parseLabel('Blue13'), ('BLUE', 13));
      expect(VisionParser.parseLabel('Black1'), ('BLACK', 1));
      expect(VisionParser.parseLabel('Yellow10'), ('YELLOW', 10));
    });

    test('maps Orange to YELLOW', () {
      expect(VisionParser.parseLabel('Orange4'), ('YELLOW', 4));
      expect(VisionParser.parseLabel('orange13'), ('YELLOW', 13));
    });

    test('maps Joker', () {
      expect(VisionParser.parseLabel('Joker'), ('JOKER', 0));
      expect(VisionParser.parseLabel('jokers'), ('JOKER', 0));
    });

    test('accepts separators', () {
      expect(VisionParser.parseLabel('Red_7'), ('RED', 7));
      expect(VisionParser.parseLabel('red-7'), ('RED', 7));
    });

    test('rejects unknown labels', () {
      expect(VisionParser.parseLabel('Green7'), isNull);
      expect(VisionParser.parseLabel('Red'), isNull);
      expect(VisionParser.parseLabel('14Red'), isNull);
    });
  });

  group('VisionParser.detectionsFromResponse', () {
    test('reads detections under an unknown workflow output key', () {
      final detections = VisionParser.detectionsFromResponse({
        'outputs': [
          {
            'tile_predictions': {
              'image': {'width': 800, 'height': 600},
              'predictions': [
                {
                  'x': 40.0,
                  'y': 50.0,
                  'width': 20.0,
                  'height': 30.0,
                  'confidence': 0.91,
                  'class': 'Red7',
                },
                {
                  'x': 80.0,
                  'y': 50.0,
                  'width': 20.0,
                  'height': 30.0,
                  'confidence': 0.88,
                  'class': 'Orange4',
                },
              ],
            },
            'output_image': {
              'type': 'base64',
              'value': 'a' * 800,
            },
          },
        ],
      });

      expect(detections, hasLength(2));
      expect(detections[0].color, 'RED');
      expect(detections[0].value, 7);
      expect(detections[1].color, 'YELLOW');
      expect(detections[1].value, 4);
    });

    test('accepts a top-level output list', () {
      final detections = VisionParser.detectionsFromResponse([
        {
          'predictions': [
            {
              'x': 1,
              'y': 2,
              'width': 10,
              'height': 10,
              'confidence': 0.7,
              'class_name': 'Joker',
            },
          ],
        },
      ]);
      expect(detections, hasLength(1));
      expect(detections.first.color, 'JOKER');
      expect(detections.first.value, 0);
    });

    test('drops detections below the 0.4 cutoff', () {
      final detections = VisionParser.detectionsFromResponse(
        {
          'outputs': [
            {
              'predictions': [
                {
                  'x': 10,
                  'y': 10,
                  'width': 10,
                  'height': 10,
                  'confidence': 0.39,
                  'class': 'Red1',
                },
                {
                  'x': 30,
                  'y': 10,
                  'width': 10,
                  'height': 10,
                  'confidence': 0.4,
                  'class': 'Red2',
                },
                {
                  'x': 50,
                  'y': 10,
                  'width': 10,
                  'height': 10,
                  'confidence': 85,
                  'class': 'Red3',
                },
              ],
            },
          ],
        },
        confidenceCutoff: 0.4,
      );

      expect(detections.map((d) => d.value), [2, 3]);
    });

    test('keeps detections from a mixed predictions list', () {
      final detections = VisionParser.detectionsFromResponse({
        'outputs': [
          {
            'predictions': [
              {
                'x': 10,
                'y': 10,
                'width': 10,
                'height': 10,
                'confidence': 0.9,
                'class': 'Red1',
              },
              {'note': 'metadata'},
            ],
          },
        ],
      });
      expect(detections, hasLength(1));
      expect(detections.single.value, 1);
    });

    test('returns empty when the prediction list is empty', () {
      final detections = VisionParser.detectionsFromResponse({
        'outputs': [
          {
            'predictions': [],
          },
        ],
      });
      expect(detections, isEmpty);
    });

    test('keeps unrecognized labels as Joker placeholders while pass-through is on',
        () {
      final detections = VisionParser.detectionsFromResponse({
        'outputs': [
          {
            'predictions': [
              {
                'x': 1,
                'y': 1,
                'width': 1,
                'height': 1,
                'confidence': 0.9,
                'class': 'Wildcard',
              },
            ],
          },
        ],
      });
      expect(detections, hasLength(1));
      expect(detections.single.color, 'JOKER');
      expect(detections.single.value, 0);
    });

    test('drops the workflow "Unknown" class instead of inventing a Joker', () {
      final detections = VisionParser.detectionsFromResponse({
        'outputs': [
          {
            'predictions': [
              {
                'x': 1,
                'y': 1,
                'width': 1,
                'height': 1,
                'confidence': 0.9,
                'class': 'Unknown',
              },
              {
                'x': 5,
                'y': 1,
                'width': 1,
                'height': 1,
                'confidence': 0.9,
                'class': 'Red7',
              },
            ],
          },
        ],
      });
      expect(detections, hasLength(1));
      expect(detections.single.color, 'RED');
      expect(detections.single.value, 7);
    });

    test('default cutoff keeps 0.15 and drops lower', () {
      final detections = VisionParser.detectionsFromResponse({
        'outputs': [
          {
            'predictions': [
              {
                'x': 10,
                'y': 10,
                'width': 10,
                'height': 10,
                'confidence': 0.14,
                'class': 'Red1',
              },
              {
                'x': 30,
                'y': 10,
                'width': 10,
                'height': 10,
                'confidence': 0.15,
                'class': 'Red2',
              },
            ],
          },
        ],
      });
      expect(detections.map((d) => d.value), [2]);
    });
  });

  group('VisionParser.gameStateFromPhotos', () {
    test('clusters board melds and orders rack tiles spatially', () {
      const table = [
        TileDetection(
          x: 20,
          y: 40,
          width: 20,
          height: 30,
          confidence: 0.9,
          color: 'RED',
          value: 1,
        ),
        TileDetection(
          x: 40,
          y: 40,
          width: 20,
          height: 30,
          confidence: 0.9,
          color: 'RED',
          value: 2,
        ),
        // A third touching tile keeps the typical neighbour gap well defined
        // (the board grouping derives its link threshold from the data).
        TileDetection(
          x: 60,
          y: 40,
          width: 20,
          height: 30,
          confidence: 0.9,
          color: 'RED',
          value: 3,
        ),
        TileDetection(
          x: 200,
          y: 40,
          width: 20,
          height: 30,
          confidence: 0.9,
          color: 'BLUE',
          value: 5,
        ),
        TileDetection(
          x: 30,
          y: 120,
          width: 20,
          height: 30,
          confidence: 0.9,
          color: 'BLACK',
          value: 8,
        ),
      ];
      const rack = [
        TileDetection(
          x: 80,
          y: 20,
          width: 20,
          height: 30,
          confidence: 0.9,
          color: 'YELLOW',
          value: 13,
        ),
        TileDetection(
          x: 20,
          y: 20,
          width: 20,
          height: 30,
          confidence: 0.9,
          color: 'JOKER',
          value: 0,
        ),
      ];

      final state = VisionParser.gameStateFromPhotos(
        boardDetections: table,
        rackDetections: rack,
      );

      expect(VisionParser.disableSpatialGrouping, isFalse);
      expect(state.board, hasLength(3));
      expect(
        state.board.map((set) => set.tiles.map((tile) => tile.value).toList()),
        [
          [1, 2, 3],
          [5],
          [8],
        ],
      );
      expect(
        state.rack.map((t) => '${t.color}${t.value}'),
        ['JOKER0', 'YELLOW13'],
      );
    });
  });

  group('VisionParser.boardSetsFromDetections (rotation aware)', () {
    List<String> labels(TileSet set) =>
        set.tiles.map((t) => '${t.color}${t.value}').toList();

    test('diagonal run at 40 degrees groups into one ordered meld', () {
      final run = _rotatedMeld(
        const [('RED', 4), ('RED', 5), ('RED', 6)],
        200,
        200,
        40,
      );
      // Shuffled input order.
      final sets = VisionParser.boardSetsFromDetections(
        [run[2], run[0], run[1]],
      );

      expect(sets, hasLength(1));
      expect(labels(sets.single), ['RED4', 'RED5', 'RED6']);
    });

    test('run rotated 180 degrees is returned ascending', () {
      // Laid out up-left from the start: left-to-right reads 6, 5, 4.
      final run = _rotatedMeld(
        const [('RED', 4), ('RED', 5), ('RED', 6)],
        300,
        300,
        220,
      );
      final sets = VisionParser.boardSetsFromDetections(run);

      expect(sets, hasLength(1));
      expect(labels(sets.single), ['RED4', 'RED5', 'RED6']);
    });

    test('vertical meld groups top to bottom', () {
      final run = _rotatedMeld(
        const [('BLUE', 9), ('BLUE', 10), ('BLUE', 11), ('BLUE', 12)],
        150,
        100,
        90,
      );
      final sets = VisionParser.boardSetsFromDetections(run.reversed.toList());

      expect(sets, hasLength(1));
      expect(labels(sets.single), ['BLUE9', 'BLUE10', 'BLUE11', 'BLUE12']);
    });

    test('two angled melds and two loose tiles are separated', () {
      final sets = VisionParser.boardSetsFromDetections([
        ..._rotatedMeld(
          const [('RED', 1), ('RED', 2), ('RED', 3)],
          100,
          100,
          25,
        ),
        ..._rotatedMeld(
          const [('BLUE', 7), ('BLACK', 7), ('YELLOW', 7)],
          600,
          350,
          130,
        ),
        _tile('BLACK', 5, 300, 650),
        _tile('YELLOW', 11, 800, 700, width: 60, height: 40),
      ]);

      expect(sets, hasLength(4));
      expect(sets.map((s) => s.tiles.length).toList()..sort(), [1, 1, 3, 3]);
      final multi = sets.where((s) => s.tiles.length == 3).toList();
      expect(
        multi.map((s) => s.tiles.map((t) => t.value).toSet()),
        containsAll([
          {1, 2, 3},
          {7},
        ]),
      );
      expect(
        labels(multi.firstWhere((s) => s.tiles.first.color == 'RED')),
        ['RED1', 'RED2', 'RED3'],
      );
      expect(
        sets.where((s) => s.tiles.length == 1).map((s) => labels(s).single),
        unorderedEquals(['BLACK5', 'YELLOW11']),
      );
    });

    test('touching parallel rows are split by perpendicular clustering', () {
      final sets = VisionParser.boardSetsFromDetections([
        for (var n = 1; n <= 4; n++)
          _tile('RED', n, 20.0 + 40 * (n - 1), 100),
        for (var n = 3; n <= 6; n++)
          _tile('BLACK', n, 20.0 + 40 * (n - 3), 160),
      ]);

      expect(sets, hasLength(2));
      expect(labels(sets[0]), ['RED1', 'RED2', 'RED3', 'RED4']);
      expect(labels(sets[1]), ['BLACK3', 'BLACK4', 'BLACK5', 'BLACK6']);
    });

    test('horizontal gaps still split melds in one row', () {
      final sets = VisionParser.boardSetsFromDetections([
        _tile('RED', 1, 20, 100),
        _tile('RED', 2, 65, 100),
        _tile('RED', 3, 110, 100),
        _tile('BLUE', 8, 210, 100),
        _tile('BLACK', 8, 255, 100),
        _tile('YELLOW', 8, 300, 100),
      ]);

      expect(sets, hasLength(2));
      expect(labels(sets[0]), ['RED1', 'RED2', 'RED3']);
      expect(labels(sets[1]), ['BLUE8', 'BLACK8', 'YELLOW8']);
    });
  });
}

TileDetection _tile(
  String color,
  int value,
  double x,
  double y, {
  double width = 40,
  double height = 60,
}) {
  return TileDetection(
    x: x,
    y: y,
    width: width,
    height: height,
    confidence: 0.9,
    color: color,
    value: value,
  );
}

/// Tiles laid along [angleDegrees]; boxes are the axis-aligned bounds of the
/// rotated tiles, so they grow and overlap like real detections.
List<TileDetection> _rotatedMeld(
  List<(String, int)> tiles,
  double startX,
  double startY,
  double angleDegrees, {
  double pitch = 42,
  double tileWidth = 40,
  double tileHeight = 60,
}) {
  final theta = angleDegrees * math.pi / 180;
  final c = math.cos(theta);
  final s = math.sin(theta);
  final boxW = tileWidth * c.abs() + tileHeight * s.abs();
  final boxH = tileWidth * s.abs() + tileHeight * c.abs();
  return [
    for (var i = 0; i < tiles.length; i++)
      _tile(
        tiles[i].$1,
        tiles[i].$2,
        startX + i * pitch * c,
        startY + i * pitch * s,
        width: boxW,
        height: boxH,
      ),
  ];
}
