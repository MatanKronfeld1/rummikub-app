import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/services/api_service.dart';

void main() {
  final state = GameState(
    board: [],
    rack: [
      Tile(id: 'r1', color: 'RED', value: 1),
      Tile(id: 'r2', color: 'RED', value: 2),
      Tile(id: 'r3', color: 'RED', value: 3),
    ],
  );

  ApiService service(MockClientHandler handler, {Duration? timeout}) =>
      ApiService(
        client: MockClient(handler),
        solveUrl: 'http://127.0.0.1:8000/solve',
        timeout: timeout ?? const Duration(seconds: 30),
      );

  Matcher solverError(String text) => throwsA(
        isA<SolverException>().having((e) => e.message, 'message', contains(text)),
      );

  test('parses the frozen /solve contract', () async {
    final api = service((request) async {
      expect(jsonDecode(request.body), state.toJson());
      return http.Response(
        jsonEncode({
          'original_state': state.toJson(),
          'optimal_state': {
            'board': [
              {
                'id': 'new',
                'type': 'RUN',
                'tiles': [for (final tile in state.rack) tile.toJson()],
              },
            ],
            'tiles_used_from_rack': 3,
            'remaining_rack': [],
          },
          'is_valid': true,
          'execution_time_ms': 42,
        }),
        200,
      );
    });

    final result = await api.solveBoard(state);

    expect(result.tilesUsedFromRack, 3);
    expect(result.executionTimeMs, 42);
    expect(result.isValid, isTrue);
    expect(result.optimalState.rack, isEmpty);
    expect(result.optimalState.board.single.tiles.map((t) => t.id), ['r1', 'r2', 'r3']);
  });

  group('solution_steps', () {
    Future<SolveResult> solveWith(Map<String, dynamic> extraOptimal) {
      final api = service((_) async => http.Response(
            jsonEncode({
              'original_state': state.toJson(),
              'optimal_state': {
                'board': [],
                'tiles_used_from_rack': 0,
                'remaining_rack': [],
                ...extraOptimal,
              },
              'is_valid': true,
              'execution_time_ms': 1,
            }),
            200,
          ));
      return api.solveBoard(state);
    }

    test('are parsed into SolutionStep objects', () async {
      final result = await solveWith({
        'solution_steps': [
          {
            'stepIndex': 0,
            'type': 'PLACE_FROM_RACK',
            'sourceSetId': null,
            'targetSetId': 'new',
            'tiles': [state.rack.first.toJson()],
            'description': 'Place red 1',
          },
        ],
      });

      final step = result.solutionSteps.single;
      expect(step.type, SolutionStepType.placeFromRack);
      expect(step.targetSetId, 'new');
      expect(step.tiles.map((t) => t.id), ['r1']);
      expect(step.description, 'Place red 1');
    });

    test('are empty when the backend omits them', () async {
      expect((await solveWith({})).solutionSteps, isEmpty);
    });

    test('a malformed list does not fail the solve', () async {
      final result = await solveWith({
        'solution_steps': [
          {'stepIndex': 0, 'type': 'NOT_A_STEP', 'tiles': []},
        ],
      });

      expect(result.solutionSteps, isEmpty);
      expect(result.isValid, isTrue);
    });
  });

  test('a rejected board shows the backend reason', () async {
    final api = service((_) async => http.Response(
          jsonEncode({'detail': 'Set 1 (id=bad) is invalid: a set must contain at least 3 tiles (found 2).'}),
          400,
        ));

    await expectLater(api.solveBoard(state), solverError('at least 3 tiles'));
  });

  test('a server error is a readable message', () async {
    final api = service((_) async => http.Response('{"detail":"Internal Server Error"}', 500));

    await expectLater(api.solveBoard(state), solverError('could not solve this board'));
  });

  test('an unreachable backend says where it looked', () async {
    final api = service((_) async => throw http.ClientException('Connection refused'));

    await expectLater(api.solveBoard(state), solverError('Could not reach the solver at 127.0.0.1'));
  });

  test('a silent backend times out with a readable message', () async {
    final api = service(
      (_) => Completer<http.Response>().future,
      timeout: const Duration(milliseconds: 10),
    );

    await expectLater(api.solveBoard(state), solverError('did not answer'));
  });

  test('an unreadable answer does not leak a parse error', () async {
    final api = service((_) async => http.Response('{"optimal_state": 3}', 200));

    await expectLater(api.solveBoard(state), solverError('cannot read'));
  });
}
