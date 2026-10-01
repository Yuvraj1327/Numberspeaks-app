import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http_parser/http_parser.dart';

import 'api_exception.dart';
import 'app_config.dart';

/// Thin wrapper around Dio that talks to the Numberspeaks FastAPI backend.
///
/// Every method here maps whatever Dio/the server returns into a single
/// [ApiException], so nothing above this layer (repositories, screens) ever
/// has to know about Dio, HTTP status codes, or raw exception text. This is
/// the ONLY place HTTP calls to the backend are made.
class ApiClient {
  ApiClient({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: '${AppConfig.apiBaseUrl}/api/v1',
                connectTimeout: AppConfig.apiConnectTimeout,
                receiveTimeout: AppConfig.apiReceiveTimeout,
              ),
            );

  final Dio _dio;

  /// Bearer token, set by AuthRepository after a successful login and
  /// removed on logout. The FastAPI backend verifies it on every report
  /// endpoint and only serves the signed-in account's own reports.
  void setAuthToken(String? token) {
    if (token == null) {
      _dio.options.headers.remove('Authorization');
    } else {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  /// GETs are idempotent, so a request that dies at the connection level
  /// (reset/closed before a response, or a proxy 502/503/504 while the
  /// server restarts) is retried a couple of times before giving up. POSTs
  /// are never retried — they could repeat a side effect.
  Future<Response<dynamic>> _getWithRetry(String path) async {
    const maxAttempts = 3;
    for (var attempt = 1;; attempt++) {
      try {
        return await _dio.get<dynamic>(path);
      } on DioException catch (e) {
        final retryable = e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.unknown ||
            const [502, 503, 504].contains(e.response?.statusCode);
        debugPrint('[ApiClient] GET $path failed (attempt $attempt/$maxAttempts): '
            '${e.type} ${e.response?.statusCode ?? ''} ${e.error ?? e.message}');
        if (!retryable || attempt >= maxAttempts) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
      }
    }
  }

  Future<Map<String, dynamic>> get(String path) async {
    try {
      final response = await _getWithRetry(path);
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<List<dynamic>> getList(String path) async {
    try {
      final response = await _getWithRetry(path);
      final data = response.data;
      if (data is List) return data;
      throw ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response shape from server.',
      );
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<Map<String, dynamic>> post(String path, {Map<String, dynamic>? body}) async {
    try {
      final response = await _dio.post<dynamic>(path, data: body);
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  /// Multipart PDF upload with progress reporting.
  Future<Map<String, dynamic>> uploadPdf(
    String path, {
    required List<int> fileBytes,
    required String fileName,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final formData = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          fileBytes,
          filename: fileName,
          contentType: MediaType('application', 'pdf'),
        ),
      });

      final response = await _dio.post<dynamic>(
        path,
        data: formData,
        options: Options(
          sendTimeout: AppConfig.apiUploadTimeout,
          receiveTimeout: AppConfig.apiUploadTimeout,
        ),
        onSendProgress: (sent, total) {
          if (onProgress != null && total > 0) {
            onProgress(sent / total);
          }
        },
      );
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    throw ApiException(
      kind: ApiErrorKind.unknown,
      message: 'Unexpected response shape from server.',
    );
  }

  ApiException _mapError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:

        return const ApiException(
          kind: ApiErrorKind.timeout,
          message: 'The request timed out.',
        );
      case DioExceptionType.connectionError:
        return _classifyLowLevel(e, 'Could not connect to the server.');
      case DioExceptionType.badCertificate:
        return const ApiException(
          kind: ApiErrorKind.network,
          message: 'Could not securely connect to the server.',
        );
      case DioExceptionType.cancel:
        return const ApiException(
          kind: ApiErrorKind.unknown,
          message: 'The request was cancelled.',
        );
      case DioExceptionType.badResponse:
        return _mapStatusError(e);
      case DioExceptionType.unknown:
        return _classifyLowLevel(e, e.message ?? 'Could not reach the server.');
    }
  }

  /// Dio reports every low-level failure (offline, DNS, reset, closed
  /// early, bad payload) as `connectionError`/`unknown`. Only a genuine
  /// "no route to the server" should tell the user to check their internet;
  /// a connection that was reached and then dropped is a different problem.
  /// (Text-matched rather than `is SocketException` so this file stays free
  /// of dart:io and keeps compiling for Flutter Web.)
  ApiException _classifyLowLevel(DioException e, String fallbackMessage) {
    final cause = '${e.error ?? e.message ?? e.type}';
    final text = cause.toLowerCase();
    final offline = text.contains('failed host lookup') ||
        text.contains('network is unreachable') ||
        text.contains('no address associated') ||
        text.contains('no route to host');
    final dropped = text.contains('reset') ||
        text.contains('closed') ||
        text.contains('broken pipe') ||
        text.contains('eof') ||
        text.contains('connection terminated');
    if (!offline && dropped) {
      return ApiException(
        kind: ApiErrorKind.interrupted,
        message: 'The connection to the server was interrupted.',
        cause: cause,
      );
    }
    if (!offline && e.type == DioExceptionType.unknown && e.error is! Exception) {
      // Not a transport error at all (e.g. an unexpected response body):
      // don't blame the user's internet.
      return ApiException(kind: ApiErrorKind.unknown, message: fallbackMessage, cause: cause);
    }
    return ApiException(kind: ApiErrorKind.network, message: fallbackMessage, cause: cause);
  }

  ApiException _mapStatusError(DioException e) {
    final statusCode = e.response?.statusCode;
    final detail = _extractDetail(e.response?.data);

    ApiErrorKind kind;
    switch (statusCode) {
      case 400:
      case 422:
        kind = ApiErrorKind.validation;
        break;
      case 401:
      case 403:
        kind = ApiErrorKind.unauthorized;
        break;
      case 404:
        kind = ApiErrorKind.notFound;
        break;
      case 409:
        kind = ApiErrorKind.conflict;
        break;
      case 501:
        kind = ApiErrorKind.notConfigured;
        break;
      default:
        if (statusCode != null && statusCode >= 500) {
          kind = ApiErrorKind.server;
        } else {
          kind = ApiErrorKind.unknown;
        }
    }

    return ApiException(kind: kind, message: detail, statusCode: statusCode);
  }

  /// The backend uses two different error-body shapes depending on where
  /// the error is raised (see app/main.py):
  ///   1. Most endpoint code raises `HTTPException(detail=...)`, which
  ///      FastAPI serializes as `{"detail": "..."}` (or, for FastAPI's own
  ///      request-parsing errors, `{"detail": [{"msg": ..., ...}, ...]}`).
  ///   2. app/main.py's global handlers for `RequestValidationError` and
  ///      any unhandled `Exception` instead return
  ///      `{"success": false, "error": "...", "details": [...]}` (no
  ///      `detail` key at all).
  /// Both are handled here so a screen always gets a real message instead
  /// of silently falling back to a generic one.
  String _extractDetail(dynamic responseData) {
    if (responseData is! Map) return '';

    if (responseData['detail'] != null) {
      final detail = responseData['detail'];
      if (detail is String) return detail;
      if (detail is List) {
        return detail
            .map((e) => e is Map && e['msg'] != null ? e['msg'].toString() : e.toString())
            .join(' ');
      }
      return detail.toString();
    }

    if (responseData['error'] != null) {
      final parts = <String>[responseData['error'].toString()];
      final details = responseData['details'];
      if (details is List) {
        parts.addAll(
          details.map((e) => e is Map && e['msg'] != null ? e['msg'].toString() : e.toString()),
        );
      }
      return parts.join(' ');
    }

    return '';
  }
}
