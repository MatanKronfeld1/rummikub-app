import 'dart:convert';

import 'package:http/http.dart' as http;

/// Session debug logger. Do not log secrets or image bytes.
void debugLog({
  required String location,
  required String message,
  required String hypothesisId,
  Map<String, Object?> data = const {},
}) {
  // #region agent log
  http
      .post(
        Uri.parse(
          'http://127.0.0.1:7308/ingest/03b4b665-2d7d-4262-9cb3-d29d24a54f4a',
        ),
        headers: const {
          'Content-Type': 'application/json',
          'X-Debug-Session-Id': 'c981a2',
        },
        body: jsonEncode({
          'sessionId': 'c981a2',
          'location': location,
          'message': message,
          'data': data,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'hypothesisId': hypothesisId,
        }),
      )
      .then((_) {}, onError: (_) {});
  // #endregion
}
