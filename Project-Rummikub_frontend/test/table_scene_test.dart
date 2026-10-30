import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/widgets/table_scene.dart';

void main() {
  const sizes = {
    'desktop': Size(1100, 900),
    'tablet': Size(768, 1024),
    'phone': Size(390, 844),
    'small phone': Size(320, 640),
  };

  Rect rotatedBounds(Rect box, double angle) {
    final c = box.center;
    final corners = [
      box.topLeft,
      box.topRight,
      box.bottomRight,
      box.bottomLeft,
    ].map((p) {
      final d = p - c;
      return c +
          Offset(
            d.dx * math.cos(angle) - d.dy * math.sin(angle),
            d.dx * math.sin(angle) + d.dy * math.cos(angle),
          );
    });
    return corners
        .map((p) => Rect.fromPoints(p, p))
        .reduce((a, b) => a.expandToInclude(b));
  }

  group('SceneLayout', () {
    for (final entry in sizes.entries) {
      group(entry.key, () {
        final layout = SceneLayout.of(entry.value);
        final scene = Offset.zero & layout.size;

        test(
            'stacks header, far rack, board, player rack, button top to '
            'bottom without overlap', () {
          expect(layout.header.bottom, lessThanOrEqualTo(layout.topRack.top));
          expect(layout.topRack.bottom, lessThan(layout.board.top));
          expect(layout.board.bottom, lessThan(layout.playerRack.top));
          expect(layout.playerRack.bottom, lessThan(layout.recognize.top));
          expect(
              layout.recognize.bottom, lessThanOrEqualTo(layout.startOver.top));
        });

        test('keeps everything inside the scene', () {
          for (final rect in [
            layout.header,
            layout.topRack,
            layout.board,
            layout.playerRack,
            layout.recognize,
            layout.startOver,
            rotatedBounds(layout.leftRack, layout.sideAngle),
            rotatedBounds(layout.rightRack, -layout.sideAngle),
          ]) {
            expect(scene.contains(rect.topLeft), isTrue, reason: '$rect');
            expect(
              rect.right,
              lessThanOrEqualTo(scene.right + 0.5),
              reason: '$rect',
            );
            expect(
              rect.bottom,
              lessThanOrEqualTo(scene.bottom + 0.5),
              reason: '$rect',
            );
          }
        });

        test('is symmetric left to right', () {
          expect(layout.topRack.center.dx, closeTo(scene.center.dx, 0.01));
          expect(layout.board.center.dx, closeTo(scene.center.dx, 0.01));
          expect(layout.playerRack.center.dx, closeTo(scene.center.dx, 0.01));
          expect(
            layout.leftRack.center.dx + layout.rightRack.center.dx,
            closeTo(scene.width, 0.01),
          );
          expect(layout.leftRack.center.dy, layout.rightRack.center.dy);
        });

        test(
            'shows depth: the far rack is smaller than the near one, and '
            'the board is wider at the near edge', () {
          expect(layout.topRack.width, lessThan(layout.playerRack.width));
          expect(layout.topRack.height, lessThan(layout.playerRack.height));
          expect(layout.boardInset, greaterThan(0));
          expect(layout.boardInset * 2, lessThan(layout.board.width / 2));
        });

        test('keeps the side racks clear of the board and the scene edge', () {
          final left = rotatedBounds(layout.leftRack, layout.sideAngle);
          final right = rotatedBounds(layout.rightRack, -layout.sideAngle);
          expect(left.left, greaterThanOrEqualTo(0));
          expect(right.right, lessThanOrEqualTo(scene.right));
          // They lean toward the board with the slanted edges.
          expect(layout.sideAngle, greaterThan(0));
          expect(layout.sideAngle, lessThan(math.pi / 6));
        });
      });
    }

    test('a short window gets the minimum height, to be scrolled', () {
      final layout = SceneLayout.of(const Size(1100, 400));

      expect(layout.size.height, SceneLayout.minHeight);
      expect(layout.board.height, greaterThan(150));
    });

    test('only narrow screens are compact', () {
      expect(SceneLayout.of(const Size(390, 844)).compact, isTrue);
      expect(SceneLayout.of(const Size(900, 800)).compact, isFalse);
    });
  });

  group('board shape', () {
    test('insetPolygon moves each edge inward by the distance', () {
      const rect = [
        Offset(0, 0),
        Offset(100, 0),
        Offset(100, 50),
        Offset(0, 50)
      ];

      final inner = insetPolygon(rect, 10);

      expect(inner, const [
        Offset(10, 10),
        Offset(90, 10),
        Offset(90, 40),
        Offset(10, 40),
      ]);
    });

    test('the outline contains the middle and not the far corners', () {
      const size = Size(400, 200);
      final path = BoardPainter.outline(size, 60);

      expect(path.contains(const Offset(200, 100)), isTrue);
      expect(path.contains(const Offset(390, 195)), isTrue);
      expect(path.contains(const Offset(3, 3)), isFalse);
      expect(path.contains(const Offset(397, 3)), isFalse);
    });
  });
}
