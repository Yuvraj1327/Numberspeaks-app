import 'package:dio/dio.dart';
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

  /// Optional bearer token, set by AuthRepository after a successful login.
  /// The FastAPI backend does not verify this yet (see README), but it is
  /// sent on every request so the backend can start enforcing it later
  /// without any Flutter-side changes.
  void setAuthToken(String? token) {
    if (token == null) {
      _dio.options.headers.remove('Authorization');
    } else {
      _dio.options.headers['Authorization'] = 'Bearer $token';
    }
  }

  Future<Map<String, dynamic>> get(String path) async {
    try {
      final response = await _dio.get<dynamic>(path);
      return _asMap(response.data);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Future<List<dynamic>> getList(String path) async {
    try {
      final response = await _dio.get<dynamic>(path);
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
        return const ApiException(
          kind: ApiErrorKind.network,
          message: 'Could not connect to the server.',
        );
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
        return ApiException(
          kind: ApiErrorKind.network,
          message: e.message ?? 'Could not reach the server.',
        );
    }
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
