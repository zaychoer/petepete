import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/token_store.dart';
import 'api_error.dart';

typedef Json = Map<String, dynamic>;

/// Base URL of the API, from `--dart-define=API_BASE_URL=https://...`.
///
/// The default is the host machine as seen from the Android emulator, for local dev.
const apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:4000',
);

/// JSON client for the Petepete API.
///
/// Authenticated calls send `Authorization: Bearer <access token>`. On a 401 the
/// client refreshes the session once (`POST /api/auth/refresh`, shared by every call
/// that fails at the same time) and retries the call with the new token; the retry
/// reuses the same body and `Idempotency-Key`. If the refresh token is rejected the
/// tokens are cleared and [onSessionExpired] fires.
///
/// Every failure is an [ApiError]; callers show `error.message`.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required http.Client httpClient,
    required TokenStore tokens,
    this.onSessionExpired,
    this.timeout = const Duration(seconds: 20),
  }) : _baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _http = httpClient,
       _tokens = tokens;

  final String _baseUrl;
  final http.Client _http;
  final TokenStore _tokens;
  final Duration timeout;

  /// Called after a refresh was rejected and the stored tokens were cleared.
  void Function()? onSessionExpired;

  Future<AuthTokens>? _refreshing;

  Future<Json> get(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
  }) => _request('GET', path, query: query, authenticated: authenticated);

  /// POST [body] as JSON. Money POSTs MUST pass an [idempotencyKey]
  /// (see `newIdempotencyKey()`); it is sent as the `Idempotency-Key` header.
  Future<Json> post(
    String path, {
    Object? body,
    String? idempotencyKey,
    bool authenticated = true,
  }) => _request(
    'POST',
    path,
    body: body,
    idempotencyKey: idempotencyKey,
    authenticated: authenticated,
  );

  Future<Json> put(String path, {Object? body, bool authenticated = true}) =>
      _request('PUT', path, body: body, authenticated: authenticated);

  Future<Json> patch(String path, {Object? body, bool authenticated = true}) =>
      _request('PATCH', path, body: body, authenticated: authenticated);

  Future<Json> delete(String path, {bool authenticated = true}) =>
      _request('DELETE', path, authenticated: authenticated);

  Future<Json> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String? idempotencyKey,
    required bool authenticated,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl$path',
    ).replace(queryParameters: query?.isEmpty ?? true ? null : query);

    Future<http.Response> send(String? accessToken) => _send(
      method,
      uri,
      body: body,
      idempotencyKey: idempotencyKey,
      accessToken: accessToken,
    );

    final sentToken = authenticated
        ? (await _tokens.read())?.accessToken
        : null;
    var response = await send(sentToken);
    if (authenticated && response.statusCode == 401) {
      final fresh = await _refresh(staleAccessToken: sentToken);
      response = await send(fresh.accessToken);
    }
    return _decode(response);
  }

  /// One refresh for any number of callers that hit a 401 together.
  Future<AuthTokens> _refresh({required String? staleAccessToken}) {
    return _refreshing ??= _doRefresh(
      staleAccessToken,
    ).whenComplete(() => _refreshing = null);
  }

  Future<AuthTokens> _doRefresh(String? staleAccessToken) async {
    final current = await _tokens.read();
    if (current == null) {
      throw ApiError(statusCode: 401, code: ApiError.unauthenticatedCode);
    }
    // A call that failed late may find the session already refreshed.
    if (current.accessToken != staleAccessToken) return current;

    // Offline throws ApiError.network here and keeps the session.
    final response = await _send(
      'POST',
      Uri.parse('$_baseUrl/api/auth/refresh'),
      body: {'refresh_token': current.refreshToken},
    );

    if (response.statusCode == 200) {
      final json = _decode(response);
      final tokens = AuthTokens(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
      );
      await _tokens.write(tokens);
      return tokens;
    }

    final error = _errorFrom(response);
    if (response.statusCode >= 400 && response.statusCode < 500) {
      await _tokens.clear();
      onSessionExpired?.call();
      throw ApiError(statusCode: 401, code: ApiError.unauthenticatedCode);
    }
    throw error;
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    Object? body,
    String? idempotencyKey,
    String? accessToken,
  }) async {
    final request = http.Request(method, uri)
      ..headers['accept'] = 'application/json';
    if (accessToken != null) {
      request.headers['authorization'] = 'Bearer $accessToken';
    }
    if (idempotencyKey != null) {
      request.headers['idempotency-key'] = idempotencyKey;
    }
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final streamed = await _http.send(request).timeout(timeout);
      return await http.Response.fromStream(streamed).timeout(timeout);
    } on http.ClientException {
      throw ApiError.network();
    } on TimeoutException {
      throw ApiError.network();
    }
  }

  Json _decode(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _errorFrom(response);
    }
    if (response.bodyBytes.isEmpty) return {};
    final decoded = _tryJson(response);
    if (decoded is Json) return decoded;
    throw ApiError(statusCode: response.statusCode, code: ApiError.serverCode);
  }

  ApiError _errorFrom(http.Response response) {
    final decoded = _tryJson(response);
    if (decoded is Json && decoded['error'] is String) {
      return ApiError(
        statusCode: response.statusCode,
        code: decoded['error'] as String,
        message: decoded['message'] as String?,
        details: decoded['details'] ?? decoded['errors'] ?? decoded['problems'],
      );
    }
    return ApiError(
      statusCode: response.statusCode,
      code: response.statusCode == 401
          ? ApiError.unauthenticatedCode
          : ApiError.serverCode,
    );
  }

  Object? _tryJson(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null;
    }
  }
}
