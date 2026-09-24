/// A single, normalized exception type for every failure that can come out
/// of [ApiClient]. Screens branch on [kind] to show the right state/message
/// and never see a raw Dio/HTTP exception.
enum ApiErrorKind {
  /// 400 / 422 — the request itself was invalid (bad file type, bad field).
  validation,

  /// 401 / 403 — not logged in, or not authorized to do this.
  unauthorized,

  /// 404 — the thing being looked up doesn't exist.
  notFound,

  /// 409 — the request conflicts with the report's current state
  /// (e.g. calculating bonus before validation has run).
  conflict,

  /// 501 — a server-side dependency isn't configured yet (e.g. the bonus
  /// formula or WhatsApp credentials haven't been provided by the client).
  notConfigured,

  /// Any other 5xx from the server.
  server,

  /// No connection, DNS failure, connection refused, etc.
  network,

  /// The request took too long.
  timeout,

  /// Anything that doesn't fit the above.
  unknown,
}

class ApiException implements Exception {
  final ApiErrorKind kind;
  final String message;
  final int? statusCode;

  const ApiException({
    required this.kind,
    required this.message,
    this.statusCode,
  });

  /// A short, non-technical message safe to show directly in the UI.
  String get userMessage {
    switch (kind) {
      case ApiErrorKind.validation:
        return message.isNotEmpty
            ? message
            : 'Some of the information provided was not valid.';
      case ApiErrorKind.unauthorized:
        return 'You are not authorized to do this. Please log in again.';
      case ApiErrorKind.notFound:
        return 'The requested item could not be found.';
      case ApiErrorKind.conflict:
        return message.isNotEmpty
            ? message
            : 'This action cannot be completed in the report\'s current state.';
      case ApiErrorKind.notConfigured:
        // This backend's 501 detail text for "not configured" is written
        // for a developer (e.g. it names a source file to edit), so it is
        // never shown as-is — only this fixed, user-safe message is.
        return 'This feature is not fully configured on the server yet. '
            'Please contact your administrator.';
      case ApiErrorKind.server:
        return 'Something went wrong on the server. Please try again shortly.';
      case ApiErrorKind.network:
        return 'Could not reach the server. Check your internet connection.';
      case ApiErrorKind.timeout:
        return 'The request took too long and timed out. Please try again.';
      case ApiErrorKind.unknown:
        return 'Something unexpected went wrong. Please try again.';
    }
  }

  @override
  String toString() => 'ApiException($kind, $statusCode): $message';
}
