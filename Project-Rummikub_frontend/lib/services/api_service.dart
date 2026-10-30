import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/solver_config.dart';
import '../models/json_map.dart';
import '../models/models.dart';

/// User-visible failure from the solver backend.
class SolverException implements Exception {
  const SolverException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// HTTP client for the Python solver backend.
class ApiService {
  ApiService({
    http.Client? client,
    String? solveUrl,
    this.timeout = const Duration(seconds: 30),
  })  : _client = client ?? http.Client(),
        _solveUrl = solveUrl ?? SolverConfig.solveUrl;

  final http.Client _client;
  final String _solveUrl;

  /// The solver itself stops after 5 seconds; the rest covers the network and
  /// a cold Cloud Run start.
  final Duration timeout;

  static const _genericError =
      'The solver could not solve this board. Please try again.';

  /// Posts [currentState] to `/solve`.
  ///
  /// Contract (frozen): response has `original_state`, `optimal_state`
  /// (`board`, `tiles_used_from_rack`, `remaining_rack`), `is_valid`,
  /// `execution_time_ms`.
  Future<SolveResult> solveBoard(GameState currentState) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(_solveUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(currentState.toJson()),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw SolverException(
        'The solver did not answer within ${timeout.inSeconds} seconds. '
        'Check that the backend is running and try again.',
      );
    } catch (_) {
      throw SolverException(
        'Could not reach the solver at ${Uri.parse(_solveUrl).host}. '
        'Check that the backend is running and try again.',
      );
    }

    switch (response.statusCode) {
      case 200:
        try {
          return _parseSolveResult(response.body, currentState);
        } catch (_) {
          throw const SolverException(
            'The solver sent an answer the app cannot read. Please try again.',
          );
        }
      case 400:
        throw SolverException(_detailFromBody(response.body));
      case 422:
        throw const SolverException(
          'The board could not be sent to the solver: some tile data is invalid.',
        );
      default:
        throw const SolverException(_genericError);
    }
  }

  SolveResult _parseSolveResult(String body, GameState currentState) {
    final decoded = asStringKeyedMap(jsonDecode(body));

    final originalJson = decoded['original_state'];
    final original = originalJson is Map
        ? GameState.fromJson(asStringKeyedMap(originalJson))
        : currentState;

    final optimal = decoded['optimal_state'];
    if (optimal is! Map) {
      throw const FormatException('optimal_state is missing');
    }
    final optimalMap = asStringKeyedMap(optimal);

    final remaining = optimalMap['rack'] ?? optimalMap['remaining_rack'];
    final optimalState = GameState.fromJson({
      'board': optimalMap['board'],
      'rack': remaining,
    });

    return SolveResult(
      originalState: original,
      optimalState: optimalState,
      tilesUsedFromRack:
          (optimalMap['tiles_used_from_rack'] as num?)?.toInt() ?? 0,
      isValid: decoded['is_valid'] == true,
      executionTimeMs: (decoded['execution_time_ms'] as num?)?.toInt() ?? 0,
    );
  }

  String _detailFromBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded['detail'] != null) {
        final detail = decoded['detail'];
        if (detail is String && detail.isNotEmpty) {
          return detail;
        }
        return detail.toString();
      }
    } catch (_) {
      // Fall through to the generic message.
    }
    return _genericError;
  }
}
