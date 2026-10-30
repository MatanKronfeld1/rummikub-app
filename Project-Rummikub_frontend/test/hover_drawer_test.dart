import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/widgets/auth_brand.dart';
import 'package:rummikub_assistant/widgets/hover_drawer.dart';

void main() {
  late TestGesture mouse;
  late List<String> chosen;

  Finder byKey(String key) => find.byKey(ValueKey(key));
  bool isOpen() => byKey('drawer-panel').evaluate().isNotEmpty;

  Future<void> pumpDrawer(WidgetTester tester) async {
    brandFontsEnabled = false;
    addTearDown(() => brandFontsEnabled = true);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    chosen = [];
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(800, 600));
    addTearDown(mouse.removePointer);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Center(child: Text('content')),
              Positioned.fill(
                child: HoverDrawer(
                  entries: [
                    DrawerEntry(
                      entryKey: const ValueKey('first'),
                      icon: Icons.history,
                      label: 'First',
                      onTap: () => chosen.add('first'),
                    ),
                    const DrawerEntry.divider(),
                    const DrawerEntry(
                      entryKey: ValueKey('off'),
                      icon: Icons.person,
                      label: 'Off',
                      onTap: null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Offset toggleCenter(WidgetTester tester) =>
      tester.getCenter(byKey('drawer-toggle'));

  /// A point well inside the open panel, away from the toggle.
  const insidePanel = Offset(150, 400);
  const outside = Offset(800, 600);

  /// Waits out the close grace period and the slide.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('starts closed with only the menu button showing',
      (tester) async {
    await pumpDrawer(tester);

    expect(isOpen(), isFalse);
    expect(byKey('drawer-toggle'), findsOneWidget);
    expect(find.text('First'), findsNothing);
  });

  testWidgets('hovering the button slides the drawer out', (tester) async {
    await pumpDrawer(tester);

    await mouse.moveTo(toggleCenter(tester));
    // One frame delivers the hover, the next builds the open drawer.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Mid-slide: it is on its way, not yet fully out.
    expect(isOpen(), isTrue);
    expect(tester.getRect(byKey('drawer-panel')).left, lessThan(0));

    await tester.pumpAndSettle();
    expect(tester.getRect(byKey('drawer-panel')).left, 0);
    expect(find.text('First'), findsOneWidget);
  });

  testWidgets('moving away closes an unpinned drawer after a grace period',
      (tester) async {
    await pumpDrawer(tester);
    await mouse.moveTo(toggleCenter(tester));
    await tester.pumpAndSettle();

    await mouse.moveTo(outside);
    await tester.pump(const Duration(milliseconds: 50));
    // Still inside the grace period: no flicker for a stray pixel.
    expect(tester.getRect(byKey('drawer-panel')).left, 0);

    await settle(tester);
    expect(isOpen(), isFalse);
  });

  testWidgets('crossing from the button onto the drawer keeps it open',
      (tester) async {
    await pumpDrawer(tester);
    await mouse.moveTo(toggleCenter(tester));
    await tester.pumpAndSettle();

    await mouse.moveTo(insidePanel);
    await settle(tester);

    expect(isOpen(), isTrue);
    await mouse.moveTo(outside);
    await settle(tester);
    expect(isOpen(), isFalse);
  });

  testWidgets('the drawer only takes pointer events where it is drawn',
      (tester) async {
    await pumpDrawer(tester);

    // Closed: a spot under where the panel would be belongs to the content.
    await mouse.moveTo(insidePanel);
    await settle(tester);
    expect(isOpen(), isFalse);
  });

  testWidgets('a click pins it open, a second click unpins it', (tester) async {
    await pumpDrawer(tester);
    await mouse.moveTo(toggleCenter(tester));
    await tester.pumpAndSettle();

    await mouse.down(toggleCenter(tester));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin), findsOneWidget);

    // Pinned: leaving does not close it.
    await mouse.moveTo(outside);
    await settle(tester);
    expect(isOpen(), isTrue);

    // Unpin with the mouse over the button: it stays until the mouse leaves.
    await mouse.moveTo(toggleCenter(tester));
    await tester.pumpAndSettle();
    await mouse.down(toggleCenter(tester));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.push_pin), findsNothing);
    expect(isOpen(), isTrue);

    await mouse.moveTo(outside);
    await settle(tester);
    expect(isOpen(), isFalse);
  });

  testWidgets('on a touch screen one tap opens it and the next closes it',
      (tester) async {
    await pumpDrawer(tester);

    await tester.tap(byKey('drawer-toggle'));
    await tester.pumpAndSettle();
    expect(isOpen(), isTrue);

    await tester.tap(byKey('drawer-toggle'));
    await tester.pumpAndSettle();
    expect(isOpen(), isFalse);
  });

  testWidgets('choosing a row runs it and closes an unpinned drawer',
      (tester) async {
    await pumpDrawer(tester);
    await mouse.moveTo(toggleCenter(tester));
    await tester.pumpAndSettle();

    await tester.tap(byKey('first'));
    await tester.pumpAndSettle();

    expect(chosen, ['first']);
    expect(isOpen(), isFalse);
  });

  testWidgets('choosing a row leaves a pinned drawer open', (tester) async {
    await pumpDrawer(tester);
    await tester.tap(byKey('drawer-toggle'));
    await tester.pumpAndSettle();

    await tester.tap(byKey('first'));
    await tester.pumpAndSettle();

    expect(chosen, ['first']);
    expect(isOpen(), isTrue);
  });

  testWidgets('a row without an action does nothing', (tester) async {
    await pumpDrawer(tester);
    await tester.tap(byKey('drawer-toggle'));
    await tester.pumpAndSettle();

    await tester.tap(byKey('off'));
    await tester.pumpAndSettle();

    expect(chosen, isEmpty);
    expect(isOpen(), isTrue);
  });

  testWidgets('the menu button says whether the menu is pinned',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpDrawer(tester);

    expect(
      tester.getSemantics(byKey('drawer-toggle')),
      matchesSemantics(
        label: 'Menu',
        hint: 'Pin the menu open',
        isButton: true,
        hasToggledState: true,
        isToggled: false,
        hasTapAction: true,
      ),
    );

    await tester.tap(byKey('drawer-toggle'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(byKey('drawer-toggle')),
      matchesSemantics(
        label: 'Menu, pinned open',
        hint: 'Unpin the menu',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('the menu button stays clear of a notch or status bar',
      (tester) async {
    brandFontsEnabled = false;
    addTearDown(() => brandFontsEnabled = true);
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.only(top: 40, left: 20),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: HoverDrawer(
                  entries: [
                    DrawerEntry(
                      icon: Icons.history,
                      label: 'First',
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 8 px of breathing room on top of the inset.
    expect(tester.getTopLeft(byKey('drawer-toggle')), const Offset(28, 48));

    await tester.tap(byKey('drawer-toggle'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);
    expect(tester.getTopLeft(byKey('drawer-toggle')), const Offset(28, 48));
  });

  testWidgets('disposing during the close grace period leaves no timer',
      (tester) async {
    await pumpDrawer(tester);
    await mouse.moveTo(toggleCenter(tester));
    await tester.pumpAndSettle();
    await mouse.moveTo(outside);
    await tester.pump(const Duration(milliseconds: 20));

    await tester.pumpWidget(const SizedBox());

    // A pending timer would fail the test on teardown.
    expect(tester.takeException(), isNull);
  });
}
