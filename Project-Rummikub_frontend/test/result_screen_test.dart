import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/result_screen.dart';
import 'package:rummikub_assistant/services/firebase_service.dart';
import 'package:rummikub_assistant/widgets/rummikub_tiles.dart';

class FakeFirebaseService extends FirebaseService {
  FakeFirebaseService({this.error});

  final Object? error;
  final saved = <(GameState before, GameState after, int tiles)>[];

  @override
  Future<void> saveSolverSolution({
    required GameState beforeState,
    required GameState afterState,
    required int tilesDropped,
  }) async {
    saved.add((beforeState, afterState, tilesDropped));
    if (error != null) throw error!;
  }
}

Tile red(int value) => Tile(id: 'r$value', color: 'RED', value: value);

final before = GameState(
  board: [
    TileSet(id: 'reds', type: 'RUN', tiles: [red(7), red(8), red(9)]),
  ],
  rack: [red(10), Tile(id: 'b2', color: 'BLUE', value: 2)],
);

final after = GameState(
  board: [
    TileSet(id: 'reds', type: 'RUN', tiles: [red(7), red(8), red(9), red(10)]),
  ],
  rack: [Tile(id: 'b2', color: 'BLUE', value: 2)],
);

void main() {
  late GameProvider provider;

  Future<void> pumpResult(
    WidgetTester tester, {
    required FakeFirebaseService firebase,
    GameState? afterState,
    int tilesDropped = 1,
    bool readOnly = false,
    List<SolutionStep> solutionSteps = const [],
  }) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    provider = GameProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<GameProvider>.value(
        value: provider,
        child: MaterialApp(
          home: ResultScreen(
            beforeState: before,
            afterState: afterState ?? after,
            tilesDropped: tilesDropped,
            executionTimeMs: 17,
            readOnly: readOnly,
            solutionSteps: solutionSteps,
            firebaseService: firebase,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the step walkthrough when the solver sent steps',
      (tester) async {
    await pumpResult(
      tester,
      firebase: FakeFirebaseService(),
      solutionSteps: [
        SolutionStep(
          stepIndex: 0,
          type: SolutionStepType.placeFromRack,
          targetSetId: 'reds',
          tiles: [red(10)],
          description: 'Place red 10 on the run',
        ),
        SolutionStep(
          stepIndex: 1,
          type: SolutionStepType.formNewSet,
          tiles: [red(7)],
          description: 'Second step',
        ),
      ],
    );

    expect(find.byKey(const ValueKey('solution-steps')), findsOneWidget);
    expect(find.text('Step 1 of 2'), findsOneWidget);
    expect(find.text('Place red 10 on the run'), findsOneWidget);

    await tester.tap(find.text('Next Step'));
    await tester.pump();
    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(find.text('Second step'), findsOneWidget);
  });

  testWidgets('hides the walkthrough when there are no steps', (tester) async {
    await pumpResult(tester, firebase: FakeFirebaseService());

    expect(find.byKey(const ValueKey('solution-steps')), findsNothing);
    expect(find.text('How to get there'), findsNothing);
  });

  testWidgets('shows before, after, placed tiles and the solve time',
      (tester) async {
    final firebase = FakeFirebaseService();
    await pumpResult(tester, firebase: firebase);

    expect(find.text('Solution'), findsOneWidget);
    expect(find.text('Tiles dropped from rack: 1'), findsOneWidget);
    expect(find.text('Solved in 17 ms'), findsOneWidget);
    expect(find.text('After'), findsOneWidget);
    expect(find.text('Before'), findsOneWidget);

    final placed = tester
        .widgetList<TileView>(
          find.descendant(
            of: find.byKey(const ValueKey('placed-from-rack')),
            matching: find.byType(TileView),
          ),
        )
        .map((view) => view.tile.id);
    expect(placed, ['r10']);

    final highlighted = tester
        .widgetList<TileView>(find.byType(TileView))
        .where((view) => view.highlighted)
        .map((view) => view.tile.id);
    // Once in the "placed" list, once on the after board; never on "before".
    expect(highlighted, ['r10', 'r10']);
  });

  testWidgets('a successful solve is saved to history once', (tester) async {
    final firebase = FakeFirebaseService();
    await pumpResult(tester, firebase: firebase);

    expect(firebase.saved, hasLength(1));
    final (savedBefore, savedAfter, tiles) = firebase.saved.single;
    expect(identical(savedBefore, before), isTrue);
    expect(identical(savedAfter, after), isTrue);
    expect(tiles, 1);
    expect(
      find.text('Saved to history and published to community challenges.'),
      findsOneWidget,
    );
    expect(provider.gameState.rack.map((tile) => tile.id), ['b2']);
  });

  testWidgets('a failed save shows a readable message', (tester) async {
    final firebase = FakeFirebaseService(
      error: Exception('You must be signed in.'),
    );
    await pumpResult(tester, firebase: firebase);

    expect(find.text('Could not save: You must be signed in.'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
  });

  testWidgets('history view does not save again', (tester) async {
    final firebase = FakeFirebaseService();
    await pumpResult(tester, firebase: firebase, readOnly: true);

    expect(firebase.saved, isEmpty);
    expect(find.text('Game details'), findsOneWidget);
  });

  testWidgets('no possible move says so plainly', (tester) async {
    final firebase = FakeFirebaseService();
    await pumpResult(
      tester,
      firebase: firebase,
      afterState: before,
      tilesDropped: 0,
    );

    expect(find.text('No legal move this turn.'), findsOneWidget);
    expect(
      find.text('None of your tiles fit on the board. Keep them and draw a tile.'),
      findsOneWidget,
    );
    expect(find.text('The board is unchanged.'), findsOneWidget);
  });

  testWidgets('shows a saving state until the save finishes', (tester) async {
    final pending = Completer<void>();
    final firebase = _SlowFirebaseService(pending.future);
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<GameProvider>(
        create: (_) => GameProvider(),
        child: MaterialApp(
          home: ResultScreen(
            beforeState: before,
            afterState: after,
            tilesDropped: 1,
            firebaseService: firebase,
          ),
        ),
      ),
    );

    expect(find.text('Saving to history...'), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('Saving to history...'), findsNothing);
  });
}

class _SlowFirebaseService extends FirebaseService {
  _SlowFirebaseService(this._done);

  final Future<void> _done;

  @override
  Future<void> saveSolverSolution({
    required GameState beforeState,
    required GameState afterState,
    required int tilesDropped,
  }) =>
      _done;
}
