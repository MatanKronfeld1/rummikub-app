import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/services/api_service.dart';

void main() {
  final state = GameState(
    board: [
      TileSet(id: 's', type: 'RUN', tiles: [
        Tile(id: 'r1', color: 'RED', value: 1),
        Tile(id: 'r2', color: 'RED', value: 2),
        Tile(id: 'r3', color: 'RED', value: 3),
      ]),
    ],
    rack: [Tile(id: 'b7', color: 'BLUE', value: 7)],
  );

  late List<http.Request> requests;
  late bool backendDown;

  GameProvider makeProvider() {
    requests = [];
    backendDown = false;
    return GameProvider(
      api: ApiService(
        solveUrl: 'http://127.0.0.1:8000/solve',
        client: MockClient((request) async {
          requests.add(request);
          if (backendDown) throw http.ClientException('down');
          if (request.url.path == '/game/turn') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'session_id': body['session_id'] ?? 'game-1',
                'turn_index':
                    requests.where((r) => r.url.path == '/game/turn').length -
                        1,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({'session_id': 'game-1', 'status': 'packed'}),
            200,
          );
        }),
      ),
    );
  }

  Iterable<http.Request> calls(String path) =>
      requests.where((r) => r.url.path == path);

  test('recordTurn opens a game, then keeps adding turns to it', () async {
    final provider = makeProvider()..updateGameState(state);

    final first = await provider.recordTurn('user-1');
    final second = await provider.recordTurn('user-1');

    expect(first!.sessionId, 'game-1');
    expect(first.turnIndex, 0);
    expect(second!.turnIndex, 1);
    expect(provider.sessionId, 'game-1');
    final firstBody = jsonDecode(calls('/game/turn').first.body) as Map;
    expect(firstBody['session_id'], isNull);
    expect(firstBody['user_id'], 'user-1');
    expect(firstBody['board'], hasLength(1));
    expect(firstBody['rack'], hasLength(1));
    expect(
      (jsonDecode(calls('/game/turn').last.body) as Map)['session_id'],
      'game-1',
    );
  });

  test('recordTurn returns null when the backend is down', () async {
    final provider = makeProvider()..updateGameState(state);
    backendDown = true;

    expect(await provider.recordTurn('user-1'), isNull);
    expect(provider.sessionId, isNull);
  });

  test('endGame ends the backend game and resets to a blank state', () async {
    final provider = makeProvider()..updateGameState(state);
    await provider.recordTurn('user-1');

    provider.endGame();
    await Future<void>.delayed(Duration.zero);

    expect(calls('/game/end'), hasLength(1));
    expect(
        jsonDecode(calls('/game/end').single.body), {'session_id': 'game-1'});
    expect(provider.sessionId, isNull);
    expect(provider.gameState.board, isEmpty);
    expect(provider.gameState.rack, isEmpty);
    expect(provider.endedGames, 1);
  });

  test('endGame with no game started calls nothing and does not throw', () {
    final provider = makeProvider()..updateGameState(state);

    provider.endGame();

    expect(requests, isEmpty);
    expect(provider.endedGames, 1);
  });

  test('a backend failure on end does not stop the reset', () async {
    final provider = makeProvider()..updateGameState(state);
    await provider.recordTurn('user-1');
    backendDown = true;

    provider.endGame();
    await Future<void>.delayed(Duration.zero);

    expect(provider.gameState.board, isEmpty);
    expect(provider.sessionId, isNull);
  });

  test('clearing the board ends the game automatically', () async {
    final provider = makeProvider()..updateGameState(state);
    await provider.recordTurn('user-1');

    provider.updateBoard([]);
    await Future<void>.delayed(Duration.zero);

    expect(calls('/game/end'), hasLength(1));
    expect(provider.sessionId, isNull);
  });

  test('a board that was already empty does not end the game', () async {
    final provider = makeProvider()
      ..updateGameState(GameState(board: [], rack: state.rack));
    await provider.recordTurn('user-1');

    provider.updateRack([]);

    expect(calls('/game/end'), isEmpty);
    expect(provider.sessionId, 'game-1');
  });

  test('solveBoard passes the game and turn to /solve', () async {
    Uri? solved;
    final api = ApiService(
      solveUrl: 'http://127.0.0.1:8000/solve',
      client: MockClient((request) async {
        solved = request.url;
        return http.Response(
          jsonEncode({
            'optimal_state': {
              'board': [],
              'tiles_used_from_rack': 0,
              'remaining_rack': [],
            },
            'is_valid': true,
            'execution_time_ms': 1,
          }),
          200,
        );
      }),
    );

    await api.solveBoard(state, sessionId: 'game-1', turnIndex: 2);

    expect(solved!.path, '/solve');
    expect(
        solved!.queryParameters, {'session_id': 'game-1', 'turn_index': '2'});
  });
}
