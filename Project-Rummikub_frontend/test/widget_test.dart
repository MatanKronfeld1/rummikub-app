import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';
import 'package:rummikub_assistant/services/roboflow_debug_dump.dart';

void main() {
  testWidgets('vision correction shows ungrouped rack tiles, not sets',
      (tester) async {
    final provider = GameProvider();
    provider.updateGameState(
      GameState(
        board: [
          TileSet(
            type: 'INVALID',
            tiles: [Tile(color: 'RED', value: 1)],
          ),
        ],
        rack: [
          Tile(color: 'BLUE', value: 7),
          Tile(color: 'JOKER', value: 0),
        ],
      ),
      fromVision: true,
      visionDebug: 'rack kept=2',
      roboflowDump: RoboflowDebugDump(
        tableJpeg: Uint8List(0),
        rackJpeg: Uint8List(0),
        tableJson: '{}',
        rackJson: '{}',
        unfilteredSummary: 'test',
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: const MaterialApp(home: CorrectionScreen()),
      ),
    );

    expect(find.text('Rack'), findsOneWidget);
    expect(find.text('2 raw tiles'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('J'), findsOneWidget);
    expect(find.text('Set 1  ·  INVALID'), findsNothing);
    expect(find.text('Solve'), findsNothing);
  });
}
