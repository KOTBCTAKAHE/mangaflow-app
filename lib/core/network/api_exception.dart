import 'package:dio/dio.dart';

/// Unified error surfaced to the UI. Built from the backend error envelope
/// `{"error": {"code", "message", "details", "request_id"}}` or from transport failures.
class ApiException implements Exception {
  const ApiException(this.code, this.message, {this.status, this.sourceId});

  final String code;
  final String message;
  final int? status;
  final String? sourceId;

  bool get isOffline => code == 'offline' || code == 'timeout';
  bool get isAuth => status == 401;
  bool get isSourceProblem => code.startsWith('source_');

  /// Human friendly, Russian.
  String get userMessage => switch (code) {
        'offline' => 'Нет подключения к серверу. Проверьте интернет или адрес сервера в настройках.',
        'timeout' => 'Сервер долго не отвечает. Попробуйте ещё раз.',
        'source_blocked' => 'Источник заблокировал запрос (гео-блок или защита сайта). Попробуйте другой источник.',
        'source_unavailable' => 'Источник сейчас недоступен. Попробуйте позже.',
        'source_auth_required' => 'Этот контент доступен только по подписке или после входа на сайте источника.',
        'source_parse_error' => 'Источник изменил формат страниц — адаптер требует обновления.',
        'rate_limited' => 'Слишком много запросов. Подождите немного.',
        _ => message.isNotEmpty ? message : 'Что-то пошло не так',
      };

  factory ApiException.fromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return const ApiException('timeout', 'timeout');
      case DioExceptionType.connectionError:
        return const ApiException('offline', 'offline');
      case DioExceptionType.cancel:
        return const ApiException('cancelled', 'cancelled');
      default:
        break;
    }
    final res = e.response;
    final data = res?.data;
    if (data is Map && data['error'] is Map) {
      final err = (data['error'] as Map).cast<String, dynamic>();
      final details = (err['details'] as Map?)?.cast<String, dynamic>();
      return ApiException(
        err['code'] as String? ?? 'error',
        err['message'] as String? ?? '',
        status: res?.statusCode,
        sourceId: details?['source_id'] as String?,
      );
    }
    if (e.error != null && res == null) return const ApiException('offline', 'offline');
    return ApiException('http_${res?.statusCode ?? 0}', 'Ошибка сервера (${res?.statusCode ?? '?'})',
        status: res?.statusCode);
  }

  @override
  String toString() => 'ApiException($code, $message)';
}
