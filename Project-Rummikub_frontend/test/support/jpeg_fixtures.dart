import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A real JPEG: a smooth gradient with a coarse checker, big enough to pass
/// the 8 KB guard and cheap to encode.
Uint8List gradientJpeg(int width, int height, {int quality = 85}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final checker = ((x ~/ 16) + (y ~/ 16)).isEven ? 24 : 0;
      image.setPixelRgb(
        x,
        y,
        (x * 255 ~/ width + checker).clamp(0, 255),
        (y * 255 ~/ height + checker).clamp(0, 255),
        (128 + 100 * sin((x + y) / 40)).round() + checker,
      );
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

/// [jpeg] with an Exif block (orientation only) right after the SOI marker,
/// where cameras put it.
Uint8List withExifOrientation(
  Uint8List jpeg,
  int orientation, {
  bool littleEndian = false,
}) {
  final tiff = ByteData(8 + 2 + 12 + 4);
  final endian = littleEndian ? Endian.little : Endian.big;
  tiff.setUint16(0, littleEndian ? 0x4949 : 0x4D4D);
  tiff.setUint16(2, 0x002A, endian);
  tiff.setUint32(4, 8, endian);
  tiff.setUint16(8, 1, endian); // one IFD entry
  tiff.setUint16(10, 0x0112, endian); // Orientation
  tiff.setUint16(12, 3, endian); // SHORT
  tiff.setUint32(14, 1, endian);
  tiff.setUint16(18, orientation, endian);
  // Next-IFD offset (last 4 bytes) stays 0.

  const exifId = [0x45, 0x78, 0x69, 0x66, 0, 0];
  final length = 2 + exifId.length + tiff.lengthInBytes;
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, length >> 8, length & 0xFF,
    ...exifId,
    ...tiff.buffer.asUint8List(),
    ...jpeg.sublist(2),
  ]);
}
