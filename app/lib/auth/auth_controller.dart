import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import 'token_store.dart';

/// Where the user is in the login lifecycle; the router follows this.
enum AuthStatus {
  /// Reading the stored session at app start.
  restoring,

  /// A stored session exists but the server could not be reached; offer a retry.
  restoreFailed,

  /// No session: login (phone, then code).
  signedOut,

  /// Logged in but the account has no display name yet (first login).
  needsName,

  /// Logged in with a name: the app proper.
  signedIn,
}

/// The logged-in account as the API reports it.
class AuthUser {
  const AuthUser({required this.id, required this.displayName});

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: json['id'] as int,
    displayName: (json['display_name'] as String?) ?? '',
  );

  final int id;
  final String displayName;
}

/// Login state and the calls that change it: request a code, verify it, set the
/// display name, restore a stored session, log out. Screens call these methods and
/// show the [ApiError.message] they throw; the router reacts to [status].
class AuthController extends ChangeNotifier {
  AuthController({required ApiClient api, required TokenStore tokens})
    : _api = api,
      _tokens = tokens {
    _api.onSessionExpired = _onSessionExpired;
  }

  final ApiClient _api;
  final TokenStore _tokens;

  AuthStatus _status = AuthStatus.restoring;
  AuthUser? _user;
  String? _pendingPhone;
  String? _restoreError;

  AuthStatus get status => _status;

  /// Set once logged in.
  AuthUser? get user => _user;

  /// The `62…` number a code was last requested for. Kept here, not in the route,
  /// so phone numbers never appear in URLs.
  String? get pendingPhone => _pendingPhone;

  /// Why [AuthStatus.restoreFailed], in Indonesian.
  String? get restoreError => _restoreError;

  /// Picks up the session a previous run stored, if any. Safe to call again from
  /// the retry button.
  Future<void> restore() async {
    _restoreError = null;
    _setStatus(AuthStatus.restoring);
    if (await _tokens.read() == null) {
      _setStatus(AuthStatus.signedOut);
      return;
    }
    try {
      _enter(AuthUser.fromJson(await _api.get('/api/me')));
    } on ApiError catch (e) {
      if (e.isUnauthenticated) {
        await _tokens.clear();
        _setStatus(AuthStatus.signedOut);
      } else {
        _restoreError = e.message;
        _setStatus(AuthStatus.restoreFailed);
      }
    }
  }

  /// Sends a code to [phone] (`62…`, see `normalizePhone`). Throws [ApiError].
  Future<void> requestOtp(String phone) async {
    await _api.post(
      '/api/auth/otp',
      body: {'phone': phone},
      authenticated: false,
    );
    _pendingPhone = phone;
    notifyListeners();
  }

  /// Checks [code] for the pending phone and starts the session. Throws [ApiError];
  /// `invalid_code` means wrong, expired or used up.
  Future<void> verifyOtp(String code) async {
    final phone = _pendingPhone;
    if (phone == null) throw StateError('verifyOtp before requestOtp');
    final json = await _api.post(
      '/api/auth/verify',
      body: {'phone': phone, 'code': code},
      authenticated: false,
    );
    await _tokens.write(
      AuthTokens(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
      ),
    );
    _pendingPhone = null;
    _enter(
      AuthUser.fromJson(json['user'] as Map<String, dynamic>),
      askName: json['new_user'] == true,
    );
  }

  /// Saves the first-login display name (`PATCH /api/me`). Throws [ApiError].
  Future<void> saveDisplayName(String name) async {
    _enter(
      AuthUser.fromJson(
        await _api.patch('/api/me', body: {'display_name': name}),
      ),
    );
  }

  /// Ends the session. The server call is best effort: the device forgets the
  /// tokens either way.
  Future<void> logout() async {
    final tokens = await _tokens.read();
    await _tokens.clear();
    _user = null;
    _pendingPhone = null;
    _setStatus(AuthStatus.signedOut);
    if (tokens == null) return;
    try {
      await _api.post(
        '/api/auth/logout',
        body: {'refresh_token': tokens.refreshToken},
        authenticated: false,
      );
    } on ApiError {
      // Offline or already invalid: nothing more to do.
    }
  }

  /// A first login, or an account that never finished the name step, asks for a name.
  void _enter(AuthUser user, {bool askName = false}) {
    _user = user;
    _setStatus(
      askName || user.displayName.trim().isEmpty
          ? AuthStatus.needsName
          : AuthStatus.signedIn,
    );
  }

  void _onSessionExpired() {
    _user = null;
    _setStatus(AuthStatus.signedOut);
  }

  void _setStatus(AuthStatus status) {
    _status = status;
    notifyListeners();
  }
}
