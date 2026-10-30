import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/logic/set_validator.dart';
import 'package:rummikub_assistant/models/models.dart';

/// Shared with the backend's tests/test_validator.py: both validators must
/// give these exact answers, so the app never accepts a board `/solve`
/// rejects (or the other way round).
const _casesPath = '../project_rummikub_backend/tests/fixtures/validator_cases.json';

List<Tile> _tiles(List<dynamic> names) {
  final tiles = <Tile>[];
  for (var i = 0; i < names.length; i++) {
    final name = names[i] as String;
    if (name == 'JOKER') {
      tiles.add(Tile(id: 't$i', color: 'JOKER', value: 0));
      continue;
    }
    final color = name.replaceAll(RegExp(r'\d+$'), '');
    tiles.add(
      Tile(
        id: 't$i',
        color: color,
        value: int.parse(name.substring(color.length)),
      ),
    );
  }
  return tiles;
}

void main() {
  final file = File(_casesPath);
  final cases = (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)[
      'cases'] as List<dynamic>;

  test('the shared fixture is present and not empty', () {
    expect(cases, isNotEmpty);
  });

  for (final raw in cases) {
    final testCase = raw as Map<String, dynamic>;
    test('parity: ${testCase['name']}', () {
      final tiles = _tiles(testCase['tiles'] as List<dynamic>);
      final validAs = testCase['valid_as'] as Map<String, dynamic>;

      for (final entry in validAs.entries) {
        final (ok, message) = SetValidator.validateSet(
          TileSet(id: 's', type: entry.key, tiles: tiles),
          0,
        );
        expect(ok, entry.value, reason: 'declared ${entry.key}: $message');
      }
      expect(
        SetValidator.classifySet(TileSet(type: 'INVALID', tiles: tiles)).type,
        testCase['classify'],
      );
    });
  }
}
