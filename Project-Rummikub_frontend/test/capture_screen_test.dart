import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:rummikub_assistant/models/models.dart';
import 'package:rummikub_assistant/providers/game_provider.dart';
import 'package:rummikub_assistant/screens/arena_list_screen.dart';
import 'package:rummikub_assistant/screens/capture_screen.dart';
import 'package:rummikub_assistant/screens/correction_screen.dart';
import 'package:rummikub_assistant/services/roboflow_debug_dump.dart';
import 'package:rummikub_assistant/services/vision_image.dart';
import 'package:rummikub_assistant/services/vision_service.dart';
import 'package:rummikub_assistant/widgets/auth_brand.dart';

/// A real JPEG of random noise, large enough to pass the 8 KB guard.
Uint8List jpegPhoto(int seed) {
  final random = Random(seed);
  final image = img.Image(width: 160, height: 120);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgb(
        x,
        y,
        random.nextInt(256),
        random.nextInt(256),
        random.nextInt(256),
      );
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 90));
}

// On IO platforms XFile.name comes from the path (the name argument is only
// used on web), as it does for files the real picker returns.
XFile photoFile(Uint8List bytes, String name) =>
    XFile.fromData(bytes, name: name, path: name, mimeType: 'image/jpeg');

class FakePicker extends ImagePicker {
  FakePicker({this.cameraAvailable = true});

  final bool cameraAvailable;
  final sources = <ImageSource>[];
  final options = <(double?, double?, int?)>[];

  /// Answers the next pickImage call.
  Future<XFile?> Function(ImageSource source) next = (_) async => null;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) {
    sources.add(source);
    options.add((maxWidth, maxHeight, imageQuality));
    return next(source);
  }

  @override
  bool supportsImageSource(ImageSource source) =>
      source == ImageSource.gallery || cameraAvailable;
}

class FakeVision extends VisionService {
  FakeVision()
      : super(
          apiKey: 'test-key',
          workflowUrl: 'https://serverless.roboflow.com/test/workflows/test',
          httpClient: MockClient((_) async => http.Response('{}', 500)),
        );

  final calls = <(Uint8List board, Uint8List rack)>[];
  Future<GameState> Function() respond = () async => GameState.empty();

  @override
  Future<GameState> processBoardAndRackFromBytes({
    required Uint8List boardImage,
    required Uint8List rackImage,
  }) {
    calls.add((boardImage, rackImage));
    return respond();
  }
}

class RecordingProvider extends GameProvider {
  final visionStates = <GameState>[];

  @override
  void updateGameState(
    GameState newState, {
    bool fromVision = false,
    String? visionDebug,
    RoboflowDebugDump? roboflowDump,
  }) {
    if (fromVision) visionStates.add(newState);
    super.updateGameState(
      newState,
      fromVision: fromVision,
      visionDebug: visionDebug,
      roboflowDump: roboflowDump,
    );
  }
}

GameState recognizedState() => GameState(
      board: [
        TileSet(
          id: 'run',
          type: 'INVALID',
          tiles: [
            Tile(id: 'r1', color: 'RED', value: 1),
            Tile(id: 'r2', color: 'RED', value: 2),
            Tile(id: 'r3', color: 'RED', value: 3),
          ],
        ),
      ],
      rack: [
        Tile(id: 'b7', color: 'BLUE', value: 7),
        Tile(id: 'j', color: 'JOKER', value: 0),
      ],
    );

void main() {
  late FakePicker picker;
  late FakeVision vision;
  late RecordingProvider provider;
  final tablePhoto = jpegPhoto(1);
  final rackPhoto = jpegPhoto(2);

  Finder byKey(String key) => find.byKey(ValueKey(key));

  late TestGesture mouse;

  Future<void> pumpScreen(
    WidgetTester tester, {
    bool camera = true,
    Size size = const Size(1200, 900),
  }) async {
    brandFontsEnabled = false;
    addTearDown(() => brandFontsEnabled = true);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    picker = FakePicker(cameraAvailable: camera);
    vision = FakeVision();
    provider = RecordingProvider();
    mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: size.bottomRight(Offset.zero) - const Offset(2, 2),
    );
    addTearDown(mouse.removePointer);
    await tester.pumpWidget(
      ChangeNotifierProvider<GameProvider>.value(
        value: provider,
        child: MaterialApp(
          home: CaptureScreen(
            picker: picker,
            visionService: vision,
            prepareImage: (bytes) async => prepareVisionJpeg(bytes),
          ),
        ),
      ),
    );
  }

  /// Moves the mouse onto the widget and lets the hover animations finish.
  Future<void> hover(WidgetTester tester, String key) async {
    await mouse.moveTo(tester.getCenter(byKey(key)));
    await tester.pumpAndSettle();
  }

  Future<void> hoverAway(WidgetTester tester) async {
    await mouse.moveTo(
        tester.getBottomRight(find.byType(Scaffold)) - const Offset(2, 2));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(byKey(key));
    await tester.tap(byKey(key), warnIfMissed: false);
  }

  bool hasPhoto(String slot) => byKey('$slot-preview').evaluate().isNotEmpty;

  /// Reaches the Camera or Gallery button the way a user does: hover the
  /// empty zone, or, once a photo is there, hover its card, press Replace and
  /// pick the source.
  Future<void> choose(
    WidgetTester tester,
    String slot,
    ImageSource source,
  ) async {
    if (hasPhoto(slot)) {
      await hover(tester, '$slot-preview-card');
      await tap(tester, '$slot-replace');
      await tester.pumpAndSettle();
    } else {
      await hover(tester, '$slot-zone');
    }
    await tap(
      tester,
      source == ImageSource.camera ? '$slot-camera' : '$slot-gallery',
    );
  }

  /// Picks [bytes] for the slot through [source] and lets the screen settle.
  Future<void> pick(
    WidgetTester tester,
    String slot,
    Uint8List bytes, {
    ImageSource source = ImageSource.gallery,
    String? name,
  }) async {
    picker.next = (_) async => photoFile(bytes, name ?? '$slot.jpg');
    await choose(tester, slot, source);
    await tester.pumpAndSettle();
  }

  Future<void> remove(WidgetTester tester, String slot) async {
    await hover(tester, '$slot-preview-card');
    await tap(tester, '$slot-remove');
    await tester.pumpAndSettle();
  }

  /// Pins the drawer open, as a tap on a touch screen does.
  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(byKey('drawer-toggle'));
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, String key) =>
      tester.widget<ButtonStyleButton>(byKey(key)).onPressed != null;

  bool entryEnabled(WidgetTester tester, String key) =>
      tester
          .widget<InkWell>(
            find.descendant(of: byKey(key), matching: find.byType(InkWell)),
          )
          .onTap !=
      null;

  /// How visible the zone's Camera/Gallery buttons are (0 hidden, 1 shown).
  double controlsOpacity(WidgetTester tester, String key) => tester
      .widget<AnimatedOpacity>(
        find
            .ancestor(of: byKey(key), matching: find.byType(AnimatedOpacity))
            .first,
      )
      .opacity;

  Uint8List previewBytes(WidgetTester tester, String slot) {
    var provider = tester.widget<Image>(byKey('$slot-preview')).image;
    if (provider is ResizeImage) provider = provider.imageProvider;
    return (provider as MemoryImage).bytes;
  }

  String errorText(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
            of: byKey('capture-error'), matching: find.byType(Text)),
      )
      .map((text) => text.data)
      .join(' ');

  testWidgets('rack stays disabled until a table photo exists', (tester) async {
    await pumpScreen(tester);

    expect(enabled(tester, 'table-camera'), isTrue);
    expect(enabled(tester, 'table-gallery'), isTrue);
    expect(enabled(tester, 'rack-camera'), isFalse);
    expect(enabled(tester, 'rack-gallery'), isFalse);
    expect(enabled(tester, 'recognize'), isFalse);

    await pick(tester, 'table', tablePhoto);

    expect(byKey('table-preview'), findsOneWidget);
    expect(find.byTooltip('table.jpg · 160×120'), findsOneWidget);
    expect(enabled(tester, 'rack-camera'), isTrue);
    expect(enabled(tester, 'rack-gallery'), isTrue);
    expect(enabled(tester, 'recognize'), isFalse);

    await pick(tester, 'rack', rackPhoto, source: ImageSource.camera);

    expect(byKey('rack-preview'), findsOneWidget);
    expect(enabled(tester, 'recognize'), isTrue);
  });

  testWidgets('camera and gallery give the same photo state', (tester) async {
    await pumpScreen(tester);

    await pick(tester, 'table', tablePhoto, source: ImageSource.camera);
    final fromCamera = previewBytes(tester, 'table');
    await pick(tester, 'table', tablePhoto, source: ImageSource.gallery);
    final fromGallery = previewBytes(tester, 'table');

    expect(picker.sources, [ImageSource.camera, ImageSource.gallery]);
    expect(fromGallery, fromCamera);
    expect(find.byTooltip('table.jpg · 160×120'), findsOneWidget);
    // Native picker resizing (the web path passes no options; see the
    // comment in CaptureScreen._pick).
    expect(picker.options, everyElement((1920.0, 1920.0, 85)));
  });

  testWidgets('cancelling the picker leaves the screen as it was',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    final before = previewBytes(tester, 'table');

    picker.next = (_) async => null;
    await choose(tester, 'table', ImageSource.camera);
    await tester.pumpAndSettle();

    expect(identical(previewBytes(tester, 'table'), before), isTrue);
    expect(byKey('capture-error'), findsNothing);
    expect(byKey('rack-preview'), findsNothing);
    expect(enabled(tester, 'recognize'), isFalse);
  });

  testWidgets('camera permission denied shows a readable way forward',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    final before = previewBytes(tester, 'table');

    picker.next = (_) async => throw PlatformException(
          code: 'camera_access_denied',
          message: 'The user did not allow camera access.',
        );
    await choose(tester, 'table', ImageSource.camera);
    await tester.pumpAndSettle();

    expect(errorText(tester), contains('Camera access is turned off'));
    expect(errorText(tester), contains('use Gallery'));
    expect(errorText(tester), isNot(contains('PlatformException')));
    expect(identical(previewBytes(tester, 'table'), before), isTrue);
  });

  testWidgets('without a camera only the gallery is offered', (tester) async {
    await pumpScreen(tester, camera: false);

    expect(enabled(tester, 'table-camera'), isFalse);
    expect(enabled(tester, 'table-gallery'), isTrue);
    expect(find.text('No camera on this device: use Gallery.'), findsWidgets);

    // With a photo there is no source to ask for: Replace goes to the gallery.
    await pick(tester, 'table', tablePhoto);
    picker.next = (_) async => photoFile(jpegPhoto(7), 'second.jpg');
    await hover(tester, 'table-preview-card');
    await tap(tester, 'table-replace');
    await tester.pumpAndSettle();

    expect(picker.sources, [ImageSource.gallery, ImageSource.gallery]);
    expect(find.byTooltip('second.jpg · 160×120'), findsOneWidget);
  });

  testWidgets('a tiny photo is rejected and the previous one is kept',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    final before = previewBytes(tester, 'table');

    await pick(tester, 'table', Uint8List(100));

    expect(errorText(tester), contains('too small'));
    expect(identical(previewBytes(tester, 'table'), before), isTrue);
  });

  testWidgets('an empty file is rejected', (tester) async {
    await pumpScreen(tester);

    await pick(tester, 'table', Uint8List(0));

    expect(errorText(tester), contains('table photo is empty or too small'));
    expect(byKey('table-preview'), findsNothing);
  });

  testWidgets(
      'a corrupt or non-image file is rejected and the previous one '
      'is kept', (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    await pick(tester, 'rack', rackPhoto);
    final before = previewBytes(tester, 'rack');

    final notAnImage = Uint8List.fromList(
      List.generate(20000, (index) => (index * 31 + 7) % 256),
    );
    await pick(tester, 'rack', notAnImage, name: 'notes.pdf');

    expect(errorText(tester), contains('rack photo is not a readable image'));
    expect(identical(previewBytes(tester, 'rack'), before), isTrue);
    expect(find.byTooltip('rack.jpg · 160×120'), findsOneWidget);
  });

  testWidgets('retaking or removing one photo leaves the other alone',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    await pick(tester, 'rack', rackPhoto);
    final table = previewBytes(tester, 'table');

    final newRack = jpegPhoto(3);
    await pick(tester, 'rack', newRack, name: 'rack-2.jpg');

    expect(identical(previewBytes(tester, 'table'), table), isTrue);
    expect(previewBytes(tester, 'rack'), newRack);
    expect(find.byTooltip('rack-2.jpg · 160×120'), findsOneWidget);
    expect(find.byTooltip('rack.jpg · 160×120'), findsNothing);

    await remove(tester, 'rack');

    expect(byKey('rack-preview'), findsNothing);
    expect(identical(previewBytes(tester, 'table'), table), isTrue);
    expect(enabled(tester, 'recognize'), isFalse);
    expect(provider.visionStates, isEmpty);

    // Removing the table keeps the rack but blocks replacing it.
    await pick(tester, 'rack', rackPhoto);
    await remove(tester, 'table');

    expect(byKey('rack-preview'), findsOneWidget);
    expect(enabled(tester, 'rack-replace'), isFalse);
    expect(enabled(tester, 'rack-remove'), isTrue);
    expect(find.text('Add the table photo to continue.'), findsOneWidget);
  });

  testWidgets('double taps open one picker and send one request',
      (tester) async {
    await pumpScreen(tester);

    final pending = Completer<XFile?>();
    picker.next = (_) => pending.future;
    await choose(tester, 'table', ImageSource.gallery);
    await tester.pump();
    await tap(tester, 'table-gallery');
    await tap(tester, 'table-camera');
    await tester.pump();
    expect(picker.sources, hasLength(1));

    pending.complete(photoFile(tablePhoto, 'table.jpg'));
    await tester.pumpAndSettle();
    await pick(tester, 'rack', rackPhoto);

    final recognition = Completer<GameState>();
    vision.respond = () => recognition.future;
    await openDrawer(tester);
    await tap(tester, 'recognize');
    await tester.pump();
    expect(byKey('capture-progress'), findsOneWidget);
    expect(enabled(tester, 'recognize'), isFalse);
    // Busy: the drawer's rows are switched off too.
    expect(entryEnabled(tester, 'manual-entry'), isFalse);
    expect(entryEnabled(tester, 'nav-account'), isFalse);
    await tap(tester, 'recognize');
    await tap(tester, 'manual-entry');
    await tester.pump();

    expect(vision.calls, hasLength(1));
    expect(picker.sources, hasLength(2));
    expect(find.byType(CorrectionScreen), findsNothing);

    recognition.complete(recognizedState());
    await tester.pumpAndSettle();
    expect(find.byType(CorrectionScreen), findsOneWidget);
    expect(provider.visionStates, hasLength(1));
  });

  testWidgets(
      'the previewed bytes are what vision receives, and its state '
      'reaches the correction screen once', (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    await pick(tester, 'rack', rackPhoto);
    final tablePreview = previewBytes(tester, 'table');
    final rackPreview = previewBytes(tester, 'rack');
    final state = recognizedState();
    vision.respond = () async => state;

    await tap(tester, 'recognize');
    await tester.pumpAndSettle();

    final (sentTable, sentRack) = vision.calls.single;
    expect(identical(sentTable, tablePreview), isTrue);
    expect(identical(sentRack, rackPreview), isTrue);
    expect(sentTable, tablePhoto);

    expect(provider.visionStates, hasLength(1));
    expect(identical(provider.visionStates.single, state), isTrue);
    final shown = provider.gameState;
    expect(
      shown.board.single.tiles.map((tile) => tile.id),
      ['r1', 'r2', 'r3'],
    );
    expect(shown.board.single.type, 'RUN');
    expect(shown.rack.map((tile) => tile.id), ['b7', 'j']);

    expect(find.byType(CorrectionScreen), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('J'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('no tiles in either photo stays here with both photos',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    await pick(tester, 'rack', rackPhoto);
    vision.respond = () async => GameState.empty();

    await tap(tester, 'recognize');
    await tester.pumpAndSettle();

    expect(find.byType(CorrectionScreen), findsNothing);
    expect(errorText(tester), contains('No tiles were recognized'));
    expect(previewBytes(tester, 'table'), tablePhoto);
    expect(previewBytes(tester, 'rack'), rackPhoto);
    expect(provider.visionStates, isEmpty);
    expect(enabled(tester, 'recognize'), isTrue);
  });

  testWidgets('a vision failure keeps the photos and allows a retry',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    await pick(tester, 'rack', rackPhoto);
    vision.respond = () async => throw const VisionException(
          'Roboflow timed out. Try a smaller photo or try again.',
        );

    await tap(tester, 'recognize');
    await tester.pumpAndSettle();

    expect(errorText(tester), contains('Roboflow timed out'));
    expect(previewBytes(tester, 'table'), tablePhoto);
    expect(previewBytes(tester, 'rack'), rackPhoto);
    expect(provider.visionStates, isEmpty);

    vision.respond = () async => recognizedState();
    await tap(tester, 'recognize');
    await tester.pumpAndSettle();

    expect(vision.calls, hasLength(2));
    expect(find.byType(CorrectionScreen), findsOneWidget);
  });

  testWidgets('an unexpected error is shown without the raw exception',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    await pick(tester, 'rack', rackPhoto);
    vision.respond = () async => throw StateError('socket closed: 0x1f');

    await tap(tester, 'recognize');
    await tester.pumpAndSettle();

    expect(errorText(tester), contains('Recognition failed'));
    expect(errorText(tester), isNot(contains('0x1f')));
  });

  testWidgets('back from the correction screen keeps both photos with a hint',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    await pick(tester, 'rack', rackPhoto);
    final table = previewBytes(tester, 'table');
    vision.respond = () async => recognizedState();

    await tap(tester, 'recognize');
    await tester.pumpAndSettle();
    expect(find.byType(CorrectionScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(CorrectionScreen), findsNothing);
    expect(identical(previewBytes(tester, 'table'), table), isTrue);
    expect(previewBytes(tester, 'rack'), rackPhoto);
    expect(byKey('capture-notice'), findsOneWidget);
    expect(enabled(tester, 'recognize'), isTrue);

    await tap(tester, 'start-over');
    await tester.pumpAndSettle();

    expect(byKey('table-preview'), findsNothing);
    expect(byKey('rack-preview'), findsNothing);
    expect(byKey('capture-notice'), findsNothing);
    expect(byKey('start-over'), findsNothing);
  });

  testWidgets('the drawer opens manual entry and the community challenge',
      (tester) async {
    await pumpScreen(tester);
    await openDrawer(tester);

    await tap(tester, 'manual-entry');
    await tester.pumpAndSettle();
    expect(find.byType(CorrectionScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tap(tester, 'community-challenge');
    await tester.pumpAndSettle();
    expect(find.byType(ArenaListScreen), findsOneWidget);
  });

  testWidgets('the drawer lists every secondary action', (tester) async {
    await pumpScreen(tester);
    await openDrawer(tester);

    for (final key in [
      'manual-entry',
      'community-challenge',
      'nav-history',
      'nav-leaderboard',
      'nav-account',
    ]) {
      expect(byKey(key), findsOneWidget, reason: key);
      expect(entryEnabled(tester, key), isTrue, reason: key);
    }
    // They are no longer buttons on the play surface.
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('a recognition finishing after the screen is gone is ignored',
      (tester) async {
    await pumpScreen(tester);
    await pick(tester, 'table', tablePhoto);
    await pick(tester, 'rack', rackPhoto);
    final recognition = Completer<GameState>();
    vision.respond = () => recognition.future;
    await tap(tester, 'recognize');
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    recognition.complete(recognizedState());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(provider.visionStates, isEmpty);
  });

  testWidgets('a pick finishing after the screen is gone is ignored',
      (tester) async {
    await pumpScreen(tester);
    final pendingPick = Completer<XFile?>();
    picker.next = (_) => pendingPick.future;
    await choose(tester, 'table', ImageSource.gallery);
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pendingPick.complete(photoFile(tablePhoto, 'table.jpg'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  group('tabletop layout and hover', () {
    testWidgets('the player rack is in the foreground with the button below it',
        (tester) async {
      await pumpScreen(tester);

      final board = tester.getRect(byKey('table-zone'));
      final rack = tester.getRect(byKey('rack-zone'));
      final recognize = tester.getRect(byKey('recognize'));

      expect(board.bottom, lessThan(rack.top));
      expect(rack.bottom, lessThan(recognize.top));
      expect(rack.center.dx, closeTo(recognize.center.dx, 1));
      expect(rack.width, greaterThan(board.width * 0.5));
      // Recognize Tiles is the prominent action, not a small link.
      expect(recognize.height, greaterThanOrEqualTo(52));
      expect(find.text('Recognize Tiles'), findsOneWidget);
    });

    testWidgets(
        'hovering the board reveals Camera and Gallery, leaving hides '
        'them', (tester) async {
      await pumpScreen(tester);
      expect(controlsOpacity(tester, 'table-camera'), 0);
      expect(controlsOpacity(tester, 'table-gallery'), 0);

      await hover(tester, 'table-zone');
      expect(controlsOpacity(tester, 'table-camera'), 1);
      expect(controlsOpacity(tester, 'table-gallery'), 1);
      expect(controlsOpacity(tester, 'rack-camera'), 0);

      await hoverAway(tester);
      expect(controlsOpacity(tester, 'table-camera'), 0);
    });

    testWidgets(
        'hovering the rack reveals its buttons, disabled until the '
        'table is photographed', (tester) async {
      await pumpScreen(tester);

      await hover(tester, 'rack-zone');
      expect(controlsOpacity(tester, 'rack-camera'), 1);
      expect(enabled(tester, 'rack-camera'), isFalse);
      expect(find.text('Photograph the table first'), findsOneWidget);

      await pick(tester, 'table', tablePhoto);
      await hover(tester, 'rack-zone');
      expect(enabled(tester, 'rack-camera'), isTrue);
      expect(find.text('Photograph the table first'), findsNothing);
    });

    testWidgets('only the board itself is hot, not the corners of its box',
        (tester) async {
      await pumpScreen(tester);
      final box = tester.getRect(byKey('table-zone'));

      // The far corners of the bounding box are outside the trapezoid.
      await mouse.moveTo(box.topLeft + const Offset(3, 3));
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester, 'table-camera'), 0);

      await mouse.moveTo(box.bottomLeft + const Offset(40, -30));
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester, 'table-camera'), 1);
    });

    testWidgets(
        'a tap reveals the buttons on a touch screen, another hides '
        'them', (tester) async {
      await pumpScreen(tester);

      await tester.tap(byKey('table-zone'));
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester, 'table-camera'), 1);

      await tester.tap(byKey('table-zone'));
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester, 'table-camera'), 0);

      // Choosing a source folds them again.
      await tester.tap(byKey('table-zone'));
      await tester.pumpAndSettle();
      picker.next = (_) async => null;
      await tester.tap(byKey('table-gallery'));
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester, 'table-camera'), 0);
    });

    testWidgets('keyboard focus on a button reveals the controls',
        (tester) async {
      await pumpScreen(tester);
      expect(controlsOpacity(tester, 'table-gallery'), 0);

      // Hidden buttons stay focusable: that is how Tab reaches them.
      final buttonIcon = find.descendant(
        of: byKey('table-gallery'),
        matching: find.byType(Icon),
      );
      Focus.of(tester.element(buttonIcon.first)).requestFocus();
      await tester.pumpAndSettle();

      expect(controlsOpacity(tester, 'table-gallery'), 1);
      expect(controlsOpacity(tester, 'table-camera'), 1);
    });

    testWidgets(
        'the photo card rests on its zone and shows Replace and '
        'Delete only while hovered', (tester) async {
      await pumpScreen(tester);
      await pick(tester, 'table', tablePhoto);
      await pick(tester, 'rack', rackPhoto);
      await hoverAway(tester);

      final board = tester.getRect(byKey('table-zone'));
      final tableCard = tester.getRect(byKey('table-preview-card'));
      expect(board.contains(tableCard.center), isTrue);
      expect(tableCard.width, lessThan(board.width / 2));

      final rack = tester.getRect(byKey('rack-zone'));
      final rackCard = tester.getRect(byKey('rack-preview-card'));
      expect(rackCard.top, lessThan(rack.top));
      expect(rackCard.bottom, greaterThan(rack.top));

      double opacity(String slot) => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: byKey('$slot-replace'),
                  matching: find.byType(AnimatedOpacity),
                )
                .first,
          )
          .opacity;
      expect(opacity('table'), 0);
      expect(opacity('rack'), 0);

      await hover(tester, 'rack-preview-card');
      expect(opacity('rack'), 1);
      expect(opacity('table'), 0);
    });

    testWidgets('Replace asks for a source, Delete removes the photo',
        (tester) async {
      await pumpScreen(tester);
      await pick(tester, 'table', tablePhoto);

      await hover(tester, 'table-preview-card');
      expect(byKey('table-camera'), findsNothing);
      await tap(tester, 'table-replace');
      await tester.pumpAndSettle();
      expect(byKey('table-camera'), findsOneWidget);
      expect(byKey('table-gallery'), findsOneWidget);
      expect(byKey('table-replace'), findsNothing);

      // Leaving and coming back starts from Replace/Delete again.
      await hoverAway(tester);
      await hover(tester, 'table-preview-card');
      expect(byKey('table-camera'), findsNothing);
      expect(byKey('table-replace'), findsOneWidget);

      await tap(tester, 'table-remove');
      await tester.pumpAndSettle();
      expect(byKey('table-preview'), findsNothing);
      // The empty board offers Camera and Gallery again at once: the mouse
      // is still over it.
      expect(controlsOpacity(tester, 'table-camera'), 1);
    });

    testWidgets('narrow phone layout keeps every part on screen',
        (tester) async {
      await pumpScreen(tester, size: const Size(360, 640));
      await pick(tester, 'table', tablePhoto);
      await pick(tester, 'rack', rackPhoto);

      expect(tester.takeException(), isNull);
      for (final key in ['table-zone', 'rack-zone', 'recognize']) {
        final rect = tester.getRect(byKey(key));
        expect(rect.left, greaterThanOrEqualTo(0), reason: key);
        expect(rect.right, lessThanOrEqualTo(360), reason: key);
      }
      expect(byKey('drawer-toggle'), findsOneWidget);
    });
  });
}
