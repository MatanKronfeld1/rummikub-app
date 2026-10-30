@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rummikub_assistant/services/vision_image.dart';
import 'package:rummikub_assistant/services/vision_image_rewrite_web.dart';
import 'package:web/web.dart' as web;

import 'support/jpeg_fixtures.dart' show withExifOrientation;

/// Run with: flutter test --platform chrome test/vision_image_web_test.dart
///
/// A photo as a camera would give it, made by the browser itself: encoding a
/// 12 MP image in Dart on JavaScript would take far longer than the code under
/// test.
Future<Uint8List> browserJpeg(int width, int height) async {
  final canvas = web.HTMLCanvasElement()
    ..width = width
    ..height = height;
  final context = canvas.getContext('2d') as web.CanvasRenderingContext2D;
  final gradient =
      context.createLinearGradient(0, 0, width.toDouble(), height.toDouble())
        ..addColorStop(0, '#c4161c')
        ..addColorStop(1, '#0c2f78');
  context.fillStyle = gradient;
  context.fillRect(0, 0, width, height);
  context.fillStyle = '#f7f3ea'.toJS;
  for (var x = 0; x < width; x += 160) {
    context.fillRect(x, height / 3, 80, height / 3);
  }
  final done = Completer<web.Blob?>();
  canvas.toBlob(
    (web.Blob? blob) {
      done.complete(blob);
    }.toJS,
    'image/jpeg',
    0.92.toJS,
  );
  final blob = (await done.future)!;
  return (await blob.arrayBuffer().toDart).toDart.asUint8List();
}

void main() {
  test('downscales a 12 MP photo with the browser codecs', () async {
    final photo = await browserJpeg(4000, 3000);

    final watch = Stopwatch()..start();
    final rewritten = await rewriteInBrowser(
      photo,
      maxSide: visionMaxSide,
      quality: visionJpegQuality,
      header: readImageHeader(photo),
    );
    watch.stop();

    expect(rewritten, isNotNull);
    expect((rewritten!.width, rewritten.height), (1920, 1440));
    final header = readImageHeader(rewritten.bytes)!;
    expect((header.width, header.height), (1920, 1440));
    expect(rewritten.bytes.length, lessThan(photo.length));
    // ignore: avoid_print
    print('browser rewrite: ${photo.length}B 4000x3000 -> '
        '${rewritten.bytes.length}B 1920x1440 in ${watch.elapsedMilliseconds} ms');
  });

  test('the browser applies the Exif orientation, so sides are swapped',
      () async {
    final stored = withExifOrientation(await browserJpeg(3200, 2400), 6);
    final header = readImageHeader(stored)!;
    expect((header.width, header.height, header.orientation), (3200, 2400, 6));

    final rewritten = await rewriteInBrowser(
      stored,
      maxSide: visionMaxSide,
      quality: visionJpegQuality,
      header: header,
    );

    // null here would mean this browser ignored EXIF and the Dart fallback
    // would be doing the work.
    expect(rewritten, isNotNull);
    expect((rewritten!.width, rewritten.height), (1440, 1920));
  });

  test('prepareVisionJpegInBackground uses it for a large photo', () async {
    final photo = await browserJpeg(3000, 2000);

    final prepared = await prepareVisionJpegInBackground(photo);

    expect(prepared.decoded, isTrue);
    expect((prepared.width, prepared.height), (1920, 1280));
    final header = readImageHeader(prepared.bytes)!;
    expect((header.width, header.height), (1920, 1280));
  });

  test('prepareVisionJpegInBackground bakes EXIF on a large photo', () async {
    final stored = withExifOrientation(await browserJpeg(3000, 2000), 6);

    final prepared = await prepareVisionJpegInBackground(stored);

    expect(prepared.bakedExif, isTrue);
    expect((prepared.width, prepared.height), (1280, 1920));
  });

  test('a photo within the limit is passed through untouched', () async {
    final photo = await browserJpeg(1600, 1200);

    final prepared = await prepareVisionJpegInBackground(photo);

    expect(identical(prepared.bytes, photo), isTrue);
    expect((prepared.width, prepared.height), (1600, 1200));
  });

  test('bytes the browser cannot decode return null for the fallback',
      () async {
    final junk = Uint8List.fromList(
      List.generate(20000, (index) => (index * 31 + 7) % 256),
    );

    final rewritten = await rewriteInBrowser(
      junk,
      maxSide: visionMaxSide,
      quality: visionJpegQuality,
    );

    expect(rewritten, isNull);
  });
}
