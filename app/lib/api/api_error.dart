/// A failed API call: the server's `error` code plus a message in Indonesian.
///
/// Auth and money endpoints answer `{"error": code}` (money ones also carry
/// `message` and `details`). When the server sends no message, [messageForCode]
/// supplies the Indonesian text, so UI code can always show [message] as is.
class ApiError implements Exception {
  ApiError({
    required this.statusCode,
    required this.code,
    String? message,
    this.details,
  }) : message = message ?? messageForCode(code);

  /// No response at all: offline, DNS, timeout.
  ApiError.network()
    : statusCode = 0,
      code = networkCode,
      details = null,
      message = messageForCode(networkCode);

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

const _messages = <String, String>{
  ApiError.networkCode:
      'Tidak bisa terhubung ke server. Cek internetmu, lalu coba lagi.',
  ApiError.serverCode: 'Server lagi bermasalah. Coba lagi sebentar lagi ya.',
  ApiError.unauthenticatedCode: 'Sesi kamu sudah berakhir. Masuk lagi ya.',
  'invalid_token': 'Sesi kamu sudah berakhir. Masuk lagi ya.',
  'invalid_phone':
      'Nomor HP tidak valid. Pakai nomor Indonesia, contoh 0812-3456-7890.',
  'rate_limited':
      'Kamu sudah terlalu sering minta kode. Tunggu sebentar, lalu coba lagi ya (maksimal 5 kali per jam).',
  'delivery_failed':
      'Kode gagal dikirim ke WhatsApp. Coba lagi sebentar lagi ya.',
  'invalid_code':
      'Kode salah atau sudah kedaluwarsa. Cek lagi, atau minta kode baru.',
  'invalid_display_name': 'Nama harus diisi, maksimal 50 karakter.',
  'still_host':
      'Kamu masih jadi host grup aktif. Serahkan atau tutup grupnya dulu.',
  'forbidden': 'Kamu tidak punya akses untuk ini.',
  'not_found': 'Data tidak ditemukan.',
  'invalid': 'Data yang dikirim belum benar. Cek lagi ya.',
};

/// Indonesian text for an API error [code]; a generic one for unknown codes.
String messageForCode(String code) =>
    _messages[code] ?? 'Permintaan ditolak. Coba lagi ya.';
