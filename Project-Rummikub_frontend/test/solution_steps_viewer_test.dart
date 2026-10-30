import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/widgets/solution_steps_viewer.dart';

SolutionStep _step(
  int i,
  SolutionStepType type,
  String description, {
  String? source,
  String? target,
}) {
  return SolutionStep(
    stepIndex: i,
    type: type,
    sourceSetId: source,
    targetSetId: target,
    tiles: [Tile(id: 't$i', color: 'RED', value: i + 1)],
    description: description,
  );
}

Widget _wrap(List<SolutionStep> steps) => MaterialApp(
      home: Scaffold(body: SolutionStepsViewer(steps: steps)),
    );

void main() {
  final steps = [
    _step(0, SolutionStepType.placeFromRack, 'Place red 1', target: 'a'),
    _step(1, SolutionStepType.moveBetweenSets, 'Move red 2',
        source: 'a', target: 'b'),
    _step(2, SolutionStepType.disbandSet, 'Disband b', source: 'b'),
  ];

  testWidgets('empty steps shows a message and no controls', (tester) async {
    await tester.pumpWidget(_wrap(const []));
    expect(find.textContaining('No steps'), findsOneWidget);
    expect(find.text('Next Step'), findsNothing);
  });

  testWidgets('starts on step 1 with Previous disabled', (tester) async {
    await tester.pumpWidget(_wrap(steps));
    expect(find.text('Step 1 of 3'), findsOneWidget);
    expect(find.text('Rack'), findsOneWidget);
    expect(find.text('Set a'), findsOneWidget);
    expect(find.text('Place red 1'), findsOneWidget);

    final prev = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Previous Step'),
    );
    expect(prev.onPressed, isNull);
  });

  testWidgets('Next and Previous move through steps', (tester) async {
    await tester.pumpWidget(_wrap(steps));

    await tester.tap(find.text('Next Step'));
    await tester.pump();
    expect(find.text('Step 2 of 3'), findsOneWidget);
    expect(find.text('Move red 2'), findsOneWidget);
    expect(find.text('Set a'), findsOneWidget);
    expect(find.text('Set b'), findsOneWidget);

    await tester.tap(find.text('Next Step'));
    await tester.pump();
    expect(find.text('Step 3 of 3'), findsOneWidget);
    expect(find.text('Free'), findsOneWidget);

    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Next Step'),
    );
    expect(next.onPressed, isNull);

    await tester.tap(find.text('Previous Step'));
    await tester.pump();
    expect(find.text('Step 2 of 3'), findsOneWidget);
  });

  test('SolutionStep.fromJson round-trips the backend payload', () {
    final json = {
      'stepIndex': 0,
      'type': 'FORM_NEW_SET',
      'sourceSetId': null,
      'targetSetId': 'n1',
      'tiles': [
        {'id': 'r1', 'color': 'RED', 'value': 1},
      ],
      'description': 'Form a set',
    };
    final step = SolutionStep.fromJson(json);
    expect(step.type, SolutionStepType.formNewSet);
    expect(step.tiles.single.id, 'r1');
    expect(step.toJson(), json);
  });
}
