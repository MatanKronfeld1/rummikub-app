import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:rummikub_assistant/services/vision_service.dart';

void main() {
  XFile fakeImage() => XFile.fromData(
        Uint8List(9000)..setAll(0, const [0xFF, 0xD8, 0xFF, 0xE0]),
        name: 'tile.jpg',
        mimeType: 'image/jpeg',
      );

  Map<String, dynamic> detectionPayload(String className) => {
        'outputs': [
          {
            'predictions': {
              'predictions': [
                {
                  'x': 10,
                  'y': 10,
                  'width': 20,
                  'height': 30,
                  'confidence': 0.9,
                  'class': className,
                },
              ],
            },
          },
        ],
      };

  test('throws a visible error when the API key is missing', () async {
    final service = VisionService(apiKey: '', httpClient: MockClient((_) async {
      fail('must not call Roboflow without an API key');
    }));

    expect(
      () => service.detectTiles(fakeImage()),
      throwsA(
        isA<VisionException>().having(
          (e) => e.message,
          'message',
          contains('API key'),
        ),
      ),
    );
  });

  test('posts base64 JSON to the workflow URL', () async {
    late http.Request captured;
    final service = VisionService(
      apiKey: 'test-key',
      workflowUrl:
          'https://serverless.roboflow.com/matan-kronfeld/workflows/rummikub-v1-logic',
      fallbackUrl: 'https://example.invalid/fallback',
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(detectionPayload('Red7')), 200);
      }),
    );

    final detections = await service.detectTiles(fakeImage());
    expect(detections, hasLength(1));
    expect(detections.first.color, 'RED');
    expect(detections.first.value, 7);
    expect(
      captured.url.toString(),
      'https://serverless.roboflow.com/matan-kronfeld/workflows/rummikub-v1-logic',
    );
    expect(captured.headers['Content-Type'], 'application/json');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['api_key'], 'test-key');
    expect(body['inputs']['image']['type'], 'base64');
    expect(body['inputs']['image']['value'], isNotEmpty);
  });

  test('retries server errors then throws instead of using mock tiles', () async {
    var calls = 0;
    final service = VisionService(
      apiKey: 'test-key',
      workflowUrl: 'https://serverless.roboflow.com/test/workflows/test',
      fallbackUrl: 'https://serverless.roboflow.com/test/workflows/test',
      timeout: const Duration(seconds: 5),
      maxAttempts: 3,
      httpClient: MockClient((_) async {
        calls += 1;
        return http.Response('{"error":"unavailable"}', 503);
      }),
    );

    await expectLater(
      service.detectTiles(fakeImage()),
      throwsA(isA<VisionException>()),
    );
    expect(calls, 3);
  });

  test('does not report Firebase HTML 200 as a Roboflow 200 failure', () async {
    var calls = 0;
    final service = VisionService(
      apiKey: 'test-key',
      workflowUrl: 'https://example.com/vision/workflow',
      fallbackUrl: '',
      maxAttempts: 3,
      httpClient: MockClient((_) async {
        calls += 1;
        return http.Response(
          '<!DOCTYPE html><html><body>flutter</body></html>',
          200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );

    await expectLater(
      service.detectTiles(fakeImage()),
      throwsA(
        isA<VisionException>().having(
          (e) => e.message,
          'message',
          contains('Vision proxy is not available'),
        ),
      ),
    );
    expect(calls, 1);
  });

  test('falls back to the infer/workflows URL on 404', () async {
    final urls = <String>[];
    final service = VisionService(
      apiKey: 'test-key',
      workflowUrl:
          'https://serverless.roboflow.com/matan-kronfeld/workflows/rummikub-v1-logic',
      fallbackUrl:
          'https://serverless.roboflow.com/infer/workflows/matan-kronfeld/rummikub-v1-logic',
      httpClient: MockClient((request) async {
        urls.add(request.url.toString());
        if (request.url.path.contains('/infer/workflows/')) {
          return http.Response(jsonEncode(detectionPayload('Orange4')), 200);
        }
        return http.Response('{"error":"not found"}', 404);
      }),
    );

    final detections = await service.detectTiles(fakeImage());
    expect(detections.single.color, 'YELLOW');
    expect(urls, [
      'https://serverless.roboflow.com/matan-kronfeld/workflows/rummikub-v1-logic',
      'https://serverless.roboflow.com/infer/workflows/matan-kronfeld/rummikub-v1-logic',
    ]);
  });
}
