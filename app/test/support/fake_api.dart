import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petepete/api/api_client.dart';
import 'package:petepete/auth/auth_controller.dart';
import 'package:petepete/auth/token_store.dart';

/// An in-memory stand-in for the Petepete API's auth and `/api/me` endpoints, run
/// behind a `MockClient` so the real [ApiClient] and screens are exercised.
///
/// Mirrors the real contract: `{"error": code}` bodies, 401 `unauthenticated` on a
/// bad bearer token, rotating refresh tokens.
class FakeApi {
  FakeApi() {
    client = MockClient(_handle);
  }

  static const baseUrl = 'http://api.test';

  late final http.Client client;

  /// The code the fake accepts at `/api/auth/verify`.
  String validCode = '123456';

  /// Makes `/api/auth/otp` answer 429 `rate_limited`.
  bool otpRateLimited = false;

  /// Makes every request fail like an offline phone.
  bool offline = false;

  /// Makes only `/api/auth/refresh` fail like an offline phone.
  bool refreshOffline = false;

  /// Accounts by normalised phone: `{id, display_name}`.
  final accounts = <String, Map<String, String>>{};

  /// Phones a code was requested for, in order.
  final otpRequests = <String>[];

  /// Every request as `METHOD path`, in order.
  final log = <String>[];

  /// `Idempotency-Key` header of each `/api/groups/g1/kas-spends` request, in order.
  final moneyKeys = <String?>[];

  int refreshCalls = 0;
  int _seq = 0;
  final _access = <String, String>{}; // access token -> phone
  final _refresh = <String, String>{}; // refresh token -> phone

  /// A logged-in account's tokens, as a previous app run would have stored them.
  AuthTokens signIn(String phone, {String displayName = 'Budi'}) {
    accounts.putIfAbsent(
      phone,
      () => {'id': 'u${++_seq}', 'display_name': displayName},
    );
    return _issue(phone);
  }

  /// Makes every access token invalid (they expire after 15 minutes in real life).
  void expireAccessTokens() => _access.clear();

  /// Makes every refresh token invalid.
  void revokeRefreshTokens() => _refresh.clear();

  AuthTokens _issue(String phone) {
    final n = ++_seq;
    _access['access-$n'] = phone;
    _refresh['refresh-$n'] = phone;
    return AuthTokens(accessToken: 'access-$n', refreshToken: 'refresh-$n');
  }

  Future<http.Response> _handle(http.Request request) async {
    final route = '${request.method} ${request.url.path}';
    log.add(route);
    if (offline || (refreshOffline && route == 'POST /api/auth/refresh')) {
      throw http.ClientException('offline');
    }
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;

    switch (route) {
      case 'POST /api/auth/otp':
        if (otpRateLimited) return _error(429, 'rate_limited');
        final phone = body['phone'] as String? ?? '';
        if (!RegExp(r'^628\d{7,11}$').hasMatch(phone)) {
          return _error(422, 'invalid_phone');
        }
        otpRequests.add(phone);
        return _json({'ok': true});
      case 'POST /api/auth/verify':
        final phone = body['phone'] as String;
        if (body['code'] != validCode) return _error(401, 'invalid_code');
        final newUser = !accounts.containsKey(phone);
        accounts.putIfAbsent(
          phone,
          () => {'id': 'u${++_seq}', 'display_name': ''},
        );
        final tokens = _issue(phone);
        return _json({
          'access_token': tokens.accessToken,
          'refresh_token': tokens.refreshToken,
          'token_type': 'Bearer',
          'expires_in': 900,
          'new_user': newUser,
          'user': _user(phone),
        });
      case 'POST /api/auth/refresh':
        refreshCalls++;
        final phone = _refresh.remove(body['refresh_token']);
        if (phone == null) return _error(401, 'invalid_token');
        final tokens = _issue(phone);
        return _json({
          'access_token': tokens.accessToken,
          'refresh_token': tokens.refreshToken,
          'token_type': 'Bearer',
          'expires_in': 900,
        });
      case 'POST /api/auth/logout':
        _refresh.remove(body['refresh_token']);
        return _json({'ok': true});
    }

    final phone = _access[_bearer(request)];
    if (phone == null) return _error(401, 'unauthenticated');
    switch (route) {
      case 'GET /api/me':
        return _json({..._user(phone), 'phone': phone});
      case 'PATCH /api/me':
        final name = (body['display_name'] as String? ?? '').trim();
        if (name.isEmpty || name.length > 50) {
          return _error(422, 'invalid_display_name');
        }
        accounts[phone]!['display_name'] = name;
        return _json({..._user(phone), 'phone': phone});
      case 'GET /api/groups':
        return _json({'groups': <Object>[]});
      case 'POST /api/groups/g1/kas-spends':
        moneyKeys.add(request.headers['idempotency-key']);
        return _json({'ok': true});
    }
    return _error(404, 'not_found');
  }

  String? _bearer(http.Request request) {
    final header = request.headers['authorization'];
    return header != null && header.startsWith('Bearer ')
        ? header.substring(7)
        : null;
  }

  Map<String, dynamic> _user(String phone) => {
    'id': accounts[phone]!['id'],
    'display_name': accounts[phone]!['display_name'],
  };

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response _error(int status, String code) =>
      _json({'error': code}, status);
}

/// Wires the real client and controller to [fake] and [tokens].
({ApiClient api, AuthController auth, MemoryTokenStore tokens}) buildApp(
  FakeApi fake, {
  MemoryTokenStore? tokens,
}) {
  final store = tokens ?? MemoryTokenStore();
  final api = ApiClient(
    baseUrl: FakeApi.baseUrl,
    httpClient: fake.client,
    tokens: store,
  );
  return (
    api: api,
    auth: AuthController(api: api, tokens: store),
    tokens: store,
  );
}
