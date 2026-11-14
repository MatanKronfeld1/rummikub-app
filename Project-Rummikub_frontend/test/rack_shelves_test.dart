import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/models/rummikub_tiles.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';
import 'package:rummikub_assistant/services/vision_parser.dart';
import 'package:rummikub_assistant/widgets/rack_widget.dart';
import 'package:rummikub_assistant/widgets/rummikub_tiles.dart';

TileDetection det(double x, double y, String color, int value) => TileDetection(
      x: x,
      y: y,
      width: 20,
      height: 30,
      confidence: 0.9,
      color: color,
      value: value,
    );

String label(Tile t) => '${t.color}${t.value}';

Tile tile(String id, String color, int value, [int? row]) =>
    Tile(id: id, color: color, value: value, rackRow: row);

void main() {
  group('rack photo -> shelves', () {
    test('two photo rows become the two shelves, left to right', () {
      final rack = VisionParser.rackTilesFromDetections([
        det(80, 20, 'YELLOW', 13),
        det(20, 20, 'JOKER', 0),
        det(50, 80, 'RED', 5),
        det(10, 80, 'BLUE', 2),
      ]);

      expect(rack.map(label), ['JOKER0', 'YELLOW13', 'BLUE2', 'RED5']);
      expect(rack.map((t) => t.rackRow), [0, 0, 1, 1]);
    });

    test('a single photo row sits on the top shelf', () {
      final rack = VisionParser.rackTilesFromDetections([
        det(20, 50, 'RED', 1),
        det(50, 50, 'RED', 2),
      ]);

      expect(rack.map((t) => t.rackRow), [0, 0]);
    });

    /// Two rows of [perRow] tiles, 60 px apart along the shelf, 100 px between
    /// shelves, turned by [degrees]. Tile `value` is its index (shelf-major).
    List<TileDetection> rackGrid(int perRow, double degrees) {
      final a = degrees * math.pi / 180;
      return [
        for (var row = 0; row < 2; row++)
          for (var i = 0; i < perRow; i++)
            TileDetection(
              x: 500 + (i * 60) * math.cos(a) - (row * 100) * math.sin(a),
              y: 500 + (i * 60) * math.sin(a) + (row * 100) * math.cos(a),
              width: 50,
              height: 80,
              confidence: 0.9,
              color: 'RED',
              value: row * perRow + i,
            ),
      ];
    }

    test('a tilted rack whose shelves overlap in y still splits in two', () {
      final boxes = rackGrid(14, 10);
      final topY = boxes.take(14).map((d) => d.y);
      final bottomY = boxes.skip(14).map((d) => d.y);
      // The case a plain "group by y" gets wrong.
      expect(topY.reduce(math.max), greaterThan(bottomY.reduce(math.min)));

      final rack = VisionParser.rackTilesFromDetections(boxes);

      expect(rack.where((t) => t.rackRow == 0).map((t) => t.value),
          [for (var i = 0; i < 14; i++) i]);
      expect(rack.where((t) => t.rackRow == 1).map((t) => t.value),
          [for (var i = 14; i < 28; i++) i]);
    });

    test('a tilt the other way splits just the same', () {
      final rack = VisionParser.rackTilesFromDetections(rackGrid(10, -8));

      expect(rack.where((t) => t.rackRow == 0), hasLength(10));
      expect(rack.where((t) => t.rackRow == 1).map((t) => t.value).first, 10);
    });

    test('stray boxes off the rack do not swallow a shelf', () {
      final boxes = [
        ...rackGrid(8, 0),
        for (var i = 0; i < 3; i++)
          TileDetection(
            x: 100.0 + i * 70,
            y: 100,
            width: 50,
            height: 80,
            confidence: 0.9,
            color: 'BLUE',
            value: 99,
          ),
      ];

      final rack = VisionParser.rackTilesFromDetections(boxes);

      // The strays join the nearest shelf (the top one); the shelves stay two.
      expect(rack.where((t) => t.rackRow == 1).map((t) => t.value),
          [for (var i = 8; i < 16; i++) i]);
      expect(rack.where((t) => t.rackRow == 0), hasLength(11));
    });

    test('tiles on a shelf are ordered along the shelf, not by raw x', () {
      final rack = VisionParser.rackTilesFromDetections(rackGrid(10, -8));

      expect(rack.where((t) => t.rackRow == 0).map((t) => t.value),
          [for (var i = 0; i < 10; i++) i]);
    });

    group('real rack photos (labeled boxes)', () {
      final photos = (jsonDecode(
        File('test/fixtures/rack_photo_layouts.json').readAsStringSync(),
      ) as List)
          .cast<Map<String, dynamic>>();

      /// Shelf sizes and mean photo y of each shelf for [photo].
      ({List<int> sizes, List<double> meanY}) layout(Map<String, dynamic> photo) {
        final boxes = [
          for (final b in (photo['boxes'] as List).cast<List>())
            TileDetection(
              x: (b[0] as num).toDouble(),
              y: (b[1] as num).toDouble(),
              width: (b[2] as num).toDouble(),
              height: (b[3] as num).toDouble(),
              confidence: 0.9,
              color: 'RED',
              value: 0,
            ),
        ];
        // Value = box index, so tiles map back to their box.
        final rack = VisionParser.rackTilesFromDetections([
          for (var i = 0; i < boxes.length; i++)
            TileDetection(
              x: boxes[i].x,
              y: boxes[i].y,
              width: boxes[i].width,
              height: boxes[i].height,
              confidence: 0.9,
              color: 'RED',
              value: i,
            ),
        ]);
        final sizes = <int>[0, 0];
        final sumY = <double>[0, 0];
        for (final tile in rack) {
          sizes[tile.rackRow!]++;
          sumY[tile.rackRow!] += boxes[tile.value].y;
        }
        return (
          sizes: sizes,
          meanY: [sumY[0] / sizes[0], sumY[1] / sizes[1]],
        );
      }

      Map<String, dynamic> photo(String name) =>
          photos.firstWhere((p) => p['photo'] == name);

      test('level rack: 9 + 9', () {
        expect(layout(photo('IMG_4410')).sizes, [9, 9]);
      });

      test('portrait photo with the rack tilted, rows overlap in y: 10 + 9', () {
        expect(layout(photo('IMG_4432')).sizes, [10, 9]);
      });

      test('handheld tilted racks (the old rule read one row)', () {
        for (final name in ['IMG_4421', 'IMG_4420']) {
          final result = layout(photo(name));
          expect(result.sizes.every((n) => n >= 9), isTrue, reason: name);
          expect(result.meanY[0], lessThan(result.meanY[1]), reason: name);
        }
      });

      test('background strays do not merge the two real shelves', () {
        final result = layout(photo('IMG_4418'));

        // 12 + 12 on the rack, 3 strays attached to the top shelf.
        expect(result.sizes, [15, 12]);
        expect(result.meanY[0], lessThan(result.meanY[1]));
      });
    });
  });

  group('Tile.rackRow', () {
    test('is layout only: not serialized, not part of equality', () {
      final on = tile('a', 'RED', 1, 1);
      final off = tile('a', 'RED', 1);

      expect(on.toJson(), off.toJson());
      expect(on.toJson().containsKey('rackRow'), isFalse);
      expect(on, off);
      expect(on.copyWith(value: 2).rackRow, 1);
    });
  });

  group('withRackRows', () {
    test('keeps the shelves tiles have and fills the top shelf first', () {
      final placed = withRackRows([
        tile('a', 'RED', 1, 1),
        tile('b', 'RED', 2),
        tile('c', 'RED', 3, 0),
        tile('d', 'RED', 4),
      ]);

      expect(placed.map((t) => t.rackRow), [1, 0, 0, 0]);
    });

    test('spills onto the bottom shelf once the top one is full', () {
      final placed = withRackRows([
        for (var i = 0; i < kRackRowCapacity + 2; i++) tile('t$i', 'RED', 1),
      ]);

      expect(placed.where((t) => t.rackRow == 0), hasLength(kRackRowCapacity));
      expect(placed.where((t) => t.rackRow == 1), hasLength(2));
      expect(placed.last.rackRow, 1);
    });

    test('takes the shelf a tile had before from `previous`', () {
      final placed = withRackRows(
        [tile('a', 'RED', 1), tile('b', 'RED', 2)],
        previous: {'b': 1},
      );

      expect(placed.map((t) => t.rackRow), [0, 1]);
    });

    test('splitRackRows keeps rack order within each shelf', () {
      final shelves = splitRackRows([
        tile('a', 'RED', 1, 1),
        tile('b', 'RED', 2, 0),
        tile('c', 'RED', 3, 1),
        tile('d', 'RED', 4, 0),
      ]);

      expect(shelves[0].map((t) => t.id), ['b', 'd']);
      expect(shelves[1].map((t) => t.id), ['a', 'c']);
    });
  });

  group('GameProvider keeps the layout', () {
    GameProvider fromPhoto() => GameProvider()
      ..updateGameState(
        GameState(
          board: const [],
          rack: [
            tile('a', 'RED', 1, 0),
            tile('b', 'RED', 2, 0),
            tile('c', 'BLUE', 3, 1),
            tile('d', 'BLUE', 4, 1),
          ],
        ),
        fromVision: true,
      );

    List<int?> rows(GameProvider p) => [for (final t in p.gameState.rack) t.rackRow];

    test('a solved rack (same ids, no rows) keeps its shelves', () {
      final provider = fromPhoto();

      provider.updateGameState(
        GameState(
          board: const [],
          // As /solve returns it: ids only, no layout.
          rack: [Tile(id: 'c', color: 'BLUE', value: 3), Tile(id: 'a', color: 'RED', value: 1)],
        ),
      );

      expect(provider.gameState.rack.map((t) => t.id), ['c', 'a']);
      expect(rows(provider), [1, 0]);
    });

    test('a new tile joins the top shelf; edits and deletes keep the rest', () {
      final provider = fromPhoto();

      provider.addTileToRack(Tile(color: 'BLACK', value: 9));
      expect(rows(provider), [0, 0, 1, 1, 0]);

      provider.replaceTile(
        provider.gameState.rack[2],
        provider.gameState.rack[2].copyWith(value: 8),
      );
      provider.deleteTile(provider.gameState.rack.first);
      expect(provider.gameState.rack.map((t) => t.id).take(3), ['b', 'c', 'd']);
      expect(rows(provider), [0, 1, 1, 0]);
    });

    test('a new photo replaces the old layout', () {
      final provider = fromPhoto();

      provider.updateGameState(
        GameState(
          board: const [],
          rack: [tile('n1', 'RED', 5, 1), tile('n2', 'RED', 6, 1)],
        ),
        fromVision: true,
      );

      expect(rows(provider), [1, 1]);
    });
  });

  group('RackWidget', () {
    Future<void> pumpRack(
      WidgetTester tester,
      List<Tile> tiles, {
      Widget? extra,
    }) {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RackWidget(tiles: tiles, onTilesAdded: (_) {}, extra: extra),
        ),
      ));
    }

    Finder inRow(int row, Finder matching) => find.descendant(
          of: find.byKey(Key('rack_row_$row')),
          matching: matching,
        );

    testWidgets('draws two shelves with each tile on its photo shelf',
        (tester) async {
      await pumpRack(tester, [
        tile('a', 'RED', 1, 0),
        tile('b', 'RED', 2, 1),
        tile('c', 'RED', 3, 0),
        tile('d', 'RED', 4, 1),
      ]);

      expect(find.byKey(const Key('rack_row_0')), findsOneWidget);
      expect(find.byKey(const Key('rack_row_1')), findsOneWidget);
      expect(inRow(0, find.byType(TileView)), findsNWidgets(2));
      expect(inRow(1, find.byType(TileView)), findsNWidgets(2));
      expect(inRow(0, find.text('1')), findsOneWidget);
      expect(inRow(0, find.text('3')), findsOneWidget);
      expect(inRow(1, find.text('2')), findsOneWidget);
      expect(inRow(1, find.text('4')), findsOneWidget);
      // The top shelf really is above the bottom one, in photo order.
      expect(
        tester.getTopLeft(find.byKey(const Key('rack_row_0'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('rack_row_1'))).dy),
      );
      expect(tester.getCenter(find.text('1')).dx,
          lessThan(tester.getCenter(find.text('3')).dx));
    });

    testWidgets('an empty rack still shows both shelves', (tester) async {
      await pumpRack(tester, const []);

      expect(find.byKey(const Key('rack_row_0')), findsOneWidget);
      expect(find.byKey(const Key('rack_row_1')), findsOneWidget);
    });

    testWidgets('the extra slot ends the shelf the next tile lands on',
        (tester) async {
      await pumpRack(
        tester,
        [tile('a', 'RED', 1, 0), tile('b', 'RED', 2, 1)],
        extra: const EmptySlot(label: 'Rack'),
      );

      expect(inRow(0, find.byType(EmptySlot)), findsOneWidget);
      expect(inRow(1, find.byType(EmptySlot)), findsNothing);
    });

    testWidgets('a long rack scrolls sideways instead of overflowing',
        (tester) async {
      await pumpRack(tester, [
        for (var i = 0; i < 24; i++) tile('t$i', 'RED', 1 + i % 13, 0),
      ]);

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('rack_row_0')), findsOneWidget);
    });
  });

  testWidgets('the correction screen lays the rack out as in the photo',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = GameProvider()
      ..updateGameState(
        GameState(
          board: const [],
          rack: VisionParser.rackTilesFromDetections([
            det(20, 20, 'RED', 7),
            det(60, 20, 'BLUE', 8),
            det(20, 80, 'BLACK', 9),
          ]),
        ),
        fromVision: true,
      );
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: provider,
      child: const MaterialApp(home: CorrectionScreen()),
    ));

    expect(
      find.descendant(
          of: find.byKey(const Key('rack_row_0')), matching: find.byType(TileView)),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
          of: find.byKey(const Key('rack_row_1')), matching: find.text('9')),
      findsOneWidget,
    );
  });
}
