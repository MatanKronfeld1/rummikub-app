import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/community_challenge_screen.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';
import 'package:rummikub_assistant/screens/leaderboard_screen.dart';
import 'package:rummikub_assistant/services/api_service.dart';

Tile tile(String id, String color, int value) =>
    Tile(id: id, color: color, value: value);

final initial = GameState(
  board: [
    TileSet(id: 's1', type: 'RUN', tiles: [
      tile('r1', 'RED', 1),
      tile('r2', 'RED', 2),
      tile('r3', 'RED', 3),
    ]),
  ],
  rack: [tile('r4', 'RED', 4), tile('b9', 'BLUE', 9)],
);

ApiService apiWith(Map<String, http.Response> routes,
    {List<http.Request>? log}) {
  return ApiService(
    solveUrl: 'http://127.0.0.1:8000/solve',
    client: MockClient((request) async {
      log?.add(request);
      return routes[request.url.path] ?? http.Response('{}', 404);
    }),
  );
}

Future<void> pump(WidgetTester tester, Widget screen, ApiService api) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<GameProvider>(
      create: (_) => GameProvider(api: api),
      child: MaterialApp(home: screen),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('score calculation', () {
    test('is rack tiles placed minus the algorithm\'s', () {
      expect(
        ChallengeResult.compare(humanPlaced: 3, aiPlaced: 2).score,
        1,
      );
      expect(
        ChallengeResult.compare(humanPlaced: 1, aiPlaced: 4).score,
        -3,
      );
      expect(
        ChallengeResult.compare(humanPlaced: 2, aiPlaced: 2).score,
        0,
      );
    });

    test('rackTilesPlaced counts only rack tiles now on the board', () {
      final played = GameState(
        board: [
          TileSet(id: 's1', type: 'RUN', tiles: [
            tile('r1', 'RED', 1),
            tile('r2', 'RED', 2),
            tile('r3', 'RED', 3),
            tile('r4', 'RED', 4),
          ]),
        ],
        rack: [tile('b9', 'BLUE', 9)],
      );
      expect(rackTilesPlaced(initial, played), 1);
      expect(rackTilesPlaced(initial, initial), 0);
    });

    test('submitChallenge parses the backend verdict', () async {
      final log = <http.Request>[];
      final api = apiWith({
        '/challenge/c1/submit': http.Response(
          jsonEncode({
            'challenge_id': 'c1',
            'human_placed': 3,
            'ai_placed': 2,
            'score': 1,
          }),
          200,
        ),
      }, log: log);
      final result = await api.submitChallenge(
        challengeId: 'c1',
        userId: 'u1',
        board: initial,
      );
      expect(result.score, 1);
      expect(result.humanPlaced, 3);
      final sent = jsonDecode(log.single.body) as Map<String, dynamic>;
      expect(sent['user_id'], 'u1');
      expect((sent['board'] as List), hasLength(1));
    });

    test('submitChallenge surfaces the backend error detail', () async {
      final api = apiWith({
        '/challenge/c1/submit': http.Response(
          jsonEncode({'detail': 'Challenge already submitted by this user.'}),
          409,
        ),
      });
      expect(
        () => api.submitChallenge(
            challengeId: 'c1', userId: 'u1', board: initial),
        throwsA(isA<SolverException>().having(
          (e) => e.message,
          'message',
          'Challenge already submitted by this user.',
        )),
      );
    });
  });

  group('CommunityChallengeScreen', () {
    testWidgets('lists challenges and opens one as a puzzle', (tester) async {
      final api = apiWith({
        '/challenge/list': http.Response(
          jsonEncode([
            {...initial.toJson(), 'id': 'c1', 'ai_score': 2},
          ]),
          200,
        ),
      });
      await pump(tester, CommunityChallengeScreen(api: api), api);

      expect(find.text('Challenge #1'), findsOneWidget);
      expect(find.textContaining('Algorithm placed 2'), findsOneWidget);
      expect(find.textContaining('2 on the rack'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('challenge-c1')));
      await tester.pumpAndSettle();

      expect(find.byType(CorrectionScreen), findsOneWidget);
      final screen =
          tester.widget<CorrectionScreen>(find.byType(CorrectionScreen));
      expect(screen.arenaChallenge!.id, 'c1');
      expect(screen.arenaChallenge!.algorithmScore, 2);
      expect(screen.arenaChallenge!.source, CorrectionScreen.communitySource);
    });

    testWidgets('says so when nothing is published yet', (tester) async {
      final api = apiWith({'/challenge/list': http.Response('[]', 200)});
      await pump(tester, CommunityChallengeScreen(api: api), api);
      expect(find.textContaining('No community challenges yet'), findsOneWidget);
    });

    testWidgets('shows an error with a retry when the backend is down',
        (tester) async {
      final api = apiWith({});
      await pump(tester, CommunityChallengeScreen(api: api), api);
      expect(find.textContaining('Could not load challenges'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('LeaderboardScreen', () {
    testWidgets('renders the ranking in backend order', (tester) async {
      final api = apiWith({
        '/leaderboard': http.Response(
          jsonEncode([
            {
              'rank': 1,
              'user_id': 'alice',
              'total_points': 5,
              'challenges_won': 2,
            },
            {
              'rank': 2,
              'user_id': 'abcdef123456',
              'total_points': 1,
              'challenges_won': 1,
            },
          ]),
          200,
        ),
      });
      await pump(tester, LeaderboardScreen(api: api), api);

      expect(find.byKey(const ValueKey('rank-1')), findsOneWidget);
      expect(find.text('alice'), findsOneWidget);
      expect(find.text('5 pts'), findsOneWidget);
      expect(find.text('2 challenges won'), findsOneWidget);
      expect(find.text('Player abcdef'), findsOneWidget);
      expect(find.text('1 challenge won'), findsOneWidget);

      final first = tester.getTopLeft(find.byKey(const ValueKey('rank-1')));
      final second = tester.getTopLeft(find.byKey(const ValueKey('rank-2')));
      expect(first.dy, lessThan(second.dy));
    });

    testWidgets('shows an empty message with no players', (tester) async {
      final api = apiWith({'/leaderboard': http.Response('[]', 200)});
      await pump(tester, LeaderboardScreen(api: api), api);
      expect(find.text('No challenges played yet.'), findsOneWidget);
    });
  });
}
