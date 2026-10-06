/// A failed API call: the server's `error` code plus its Indonesian `message`.
///
/// Every error body carries `message` (ADR-0004), so UI code shows [message] as is.
/// Only failures with no usable body (offline, a 5xx page, a refresh that
/// cannot say more) get the local fallback text below.
class ApiError implements Exception {
  ApiError({
    required this.statusCode,
    required this.code,
    String? message,
    this.details,
  }) : message = message ?? _fallbackFor(code);

  /// No response at all: offline, DNS, timeout.
  ApiError.network()
    : statusCode = 0,
      code = networkCode,
      details = null,
      message = _fallbackFor(networkCode);

  /// HTTP status, or 0 when there was no response ([isNetwork]).
  final int statusCode;

  /// Stable machine code such as `rate_limited`, `invalid_code`, `unauthenticated`.
  final String code;

  /// Text safe to show to the user.
  final String message;

  /// Per-field errors from `invalid_params` / `invalid` responses, if any.
  final Object? details;

  static const networkCode = 'network_error';
  static const serverCode = 'server_error';
  static const unauthenticatedCode = 'unauthenticated';

  bool get isNetwork => code == networkCode;
  bool get isUnauthenticated => statusCode == 401;
  bool get isRateLimited => code == 'rate_limited';

  @override
  String toString() => 'ApiError($statusCode $code)';
}

const _fallbacks = <String, String>{
  ApiError.networkCode:
      'Tidak bisa terhubung ke server. Cek internetmu, lalu coba lagi.',
  ApiError.serverCode: 'Server lagi bermasalah. Coba lagi sebentar lagi ya.',
  ApiError.unauthenticatedCode: 'Sesi kamu sudah berakhir. Masuk lagi ya.',
};

String _fallbackFor(String code) =>
    _fallbacks[code] ?? 'Permintaan ditolak. Coba lagi ya.';
