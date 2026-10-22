import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../debug_log.dart';

/// JPEG ready for Roboflow: EXIF baked into pixels, longest side <= [maxSide].
class PreparedVisionImage {
  const PreparedVisionImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.exifOrientation,
    required this.bakedExif,
    required this.decoded,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int? exifOrientation;
  final bool bakedExif;
  final bool decoded;

  String get debugLine {
    final orient = exifOrientation == null ? 'none' : '$exifOrientation';
    return '${bytes.length}B ${width}x$height EXIF=$orient baked=$bakedExif';
  }
}

PreparedVisionImage prepareVisionJpeg(
  Uint8List bytes, {
  int maxSide = 1920,
  int quality = 85,
}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    // #region agent log
    debugLog(
      location: 'vision_image.dart:prepareVisionJpeg',
      message: 'decode failed, sending original bytes',
      hypothesisId: 'H1',
      data: {'byteLen': bytes.length},
    );
    // #endregion
    return PreparedVisionImage(
      bytes: bytes,
      width: 0,
      height: 0,
      exifOrientation: null,
      bakedExif: false,
      decoded: false,
    );
  }

  final orientation = decoded.exif.imageIfd.hasOrientation
      ? decoded.exif.imageIfd.orientation
      : null;
  final needsBake = orientation != null && orientation != 1;
  var image = needsBake ? img.bakeOrientation(decoded) : decoded;

  final longest = image.width > image.height ? image.width : image.height;
  final needsResize = longest > maxSide;
  if (!needsBake && !needsResize) {
    // #region agent log
    debugLog(
      location: 'vision_image.dart:prepareVisionJpeg',
      message: 'skipped re-encode; EXIF already upright',
      hypothesisId: 'H15',
      data: {
        'inBytes': bytes.length,
        'width': image.width,
        'height': image.height,
        'exifOrientation': orientation,
      },
    );
    // #endregion
    return PreparedVisionImage(
      bytes: bytes,
      width: image.width,
      height: image.height,
      exifOrientation: orientation,
      bakedExif: false,
      decoded: true,
    );
  }
  if (longest > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: maxSide,
            interpolation: img.Interpolation.linear,
          )
        : img.copyResize(
            image,
            height: maxSide,
            interpolation: img.Interpolation.linear,
          );
  }

  final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: quality));
  // #region agent log
  debugLog(
    location: 'vision_image.dart:prepareVisionJpeg',
    message: 'prepared jpeg for inference',
    hypothesisId: 'H1',
    data: {
      'inBytes': bytes.length,
      'outBytes': jpeg.length,
      'width': image.width,
      'height': image.height,
      'exifOrientation': orientation,
      'bakedExif': needsBake,
    },
  );
  // #endregion
  return PreparedVisionImage(
    bytes: jpeg,
    width: image.width,
    height: image.height,
    exifOrientation: orientation,
    bakedExif: needsBake,
    decoded: true,
  );
}
