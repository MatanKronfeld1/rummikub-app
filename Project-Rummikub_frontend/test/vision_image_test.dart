import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rummikub_assistant/services/vision_image.dart';

import 'support/jpeg_fixtures.dart';

void main() {
  group('readImageHeader', () {
    test('reads the size of a JPEG without an Exif block', () {
      final header = readImageHeader(gradientJpeg(320, 200))!;

      expect((header.width, header.height), (320, 200));
      expect(header.orientation, isNull);
      expect(header.needsBake, isFalse);
    });

    test('reads the Exif orientation in either byte order', () {
      final jpeg = gradientJpeg(320, 200);

      for (final littleEndian in [false, true]) {
        final header = readImageHeader(
          withExifOrientation(jpeg, 6, littleEndian: littleEndian),
        )!;
        expect(header.orientation, 6);
        expect(header.needsBake, isTrue);
        // The file's own sides, before rotation.
        expect((header.width, header.height), (320, 200));
      }
      expect(
        readImageHeader(withExifOrientation(jpeg, 1))!.needsBake,
        isFalse,
      );
    });

    test('reads a PNG header', () {
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 50, height: 70)),
      );

      final header = readImageHeader(png)!;

      expect((header.width, header.height), (50, 70));
      expect(header.orientation, isNull);
    });

    test('returns null for anything it cannot read safely', () {
      final jpeg = gradientJpeg(64, 64);
      expect(readImageHeader(Uint8List(0)), isNull);
      expect(readImageHeader(Uint8List(100)), isNull);
      expect(readImageHeader(jpeg.sublist(0, 3)), isNull);
      // Cut inside the header segments, before any frame header.
      expect(readImageHeader(jpeg.sublist(0, 10)), isNull);
      expect(
        readImageHeader(
          Uint8List.fromList(img.encodeBmp(img.Image(width: 8, height: 8))),
        ),
        isNull,
      );
    });
  });

  group('prepareVisionJpeg', () {
    test('keeps an upright photo within the limit byte for byte', () {
      final jpeg = gradientJpeg(1600, 1200);

      final prepared = prepareVisionJpeg(jpeg);

      expect(identical(prepared.bytes, jpeg), isTrue);
      expect((prepared.width, prepared.height), (1600, 1200));
      expect(prepared.decoded, isTrue);
      expect(prepared.bakedExif, isFalse);
    });

    test('answers from the header: pixel data is never decoded', () {
      // Valid header, entropy-coded data cut off. A decode would choke.
      final jpeg = gradientJpeg(1600, 1200);
      final cut = Uint8List.sublistView(jpeg, 0, 2000);

      final prepared = prepareVisionJpeg(cut);

      expect(identical(prepared.bytes, cut), isTrue);
      expect((prepared.width, prepared.height), (1600, 1200));
    });

    test('downscales a large photo to the longest side, once', () {
      final prepared = prepareVisionJpeg(gradientJpeg(2400, 1600));

      expect((prepared.width, prepared.height), (visionMaxSide, 1280));
      final header = readImageHeader(prepared.bytes)!;
      expect((header.width, header.height), (visionMaxSide, 1280));
      expect(prepared.decoded, isTrue);
    });

    test('bakes a sideways Exif orientation into the pixels', () {
      final sideways = withExifOrientation(gradientJpeg(1200, 800), 6);

      final prepared = prepareVisionJpeg(sideways);

      expect(prepared.bakedExif, isTrue);
      expect(prepared.exifOrientation, 6);
      expect((prepared.width, prepared.height), (800, 1200));
      final header = readImageHeader(prepared.bytes)!;
      expect((header.width, header.height), (800, 1200));
      expect(header.orientation, isNull);
    });

    test('bakes an upside-down photo that keeps its size', () {
      final upsideDown = withExifOrientation(gradientJpeg(1200, 800), 3);

      final prepared = prepareVisionJpeg(upsideDown);

      expect(prepared.bakedExif, isTrue);
      expect(identical(prepared.bytes, upsideDown), isFalse);
      expect((prepared.width, prepared.height), (1200, 800));
    });

    test('ignores an orientation tag that is already upright', () {
      final jpeg = withExifOrientation(gradientJpeg(640, 480), 1);

      final prepared = prepareVisionJpeg(jpeg);

      expect(identical(prepared.bytes, jpeg), isTrue);
      expect(prepared.exifOrientation, 1);
    });

    test('formats without a header reader still decode in full', () {
      final bmp = Uint8List.fromList(
        img.encodeBmp(img.Image(width: 120, height: 90)),
      );

      final prepared = prepareVisionJpeg(bmp);

      expect(prepared.decoded, isTrue);
      expect((prepared.width, prepared.height), (120, 90));
    });

    test('flags bytes that are not an image', () {
      final junk = Uint8List.fromList(
        List.generate(20000, (index) => (index * 31 + 7) % 256),
      );

      final prepared = prepareVisionJpeg(junk);

      expect(prepared.decoded, isFalse);
      expect(identical(prepared.bytes, junk), isTrue);
    });
  });

  group('prepareVisionJpegInBackground', () {
    test('returns the same bytes without an isolate for a small photo',
        () async {
      final jpeg = gradientJpeg(1280, 960);

      final prepared = await prepareVisionJpegInBackground(jpeg);

      // An isolate would hand back a copy; the header path cannot.
      expect(identical(prepared.bytes, jpeg), isTrue);
    });

    test('resizes a large photo in a background isolate', () async {
      final prepared =
          await prepareVisionJpegInBackground(gradientJpeg(2400, 1600));

      expect((prepared.width, prepared.height), (visionMaxSide, 1280));
      expect(prepared.decoded, isTrue);
    });
  });
}
