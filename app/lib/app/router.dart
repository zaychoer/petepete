import 'package:go_router/go_router.dart';

import '../auth/auth_controller.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/name_screen.dart';
import '../features/auth/otp_screen.dart';
import '../features/auth/restore_screen.dart';
import '../features/home/placeholder_screen.dart';
import '../features/kas/kas_routes.dart';
import '../features/session/session_routes.dart';

/// Route names; navigate with `context.goNamed(AppRoutes.home)`. Later tickets add
/// their names here, under [home] (e.g. a group is `/grup/:groupId`).
abstract final class AppRoutes {
  static const restore = 'restore';
  static const login = 'login';
  static const otp = 'otp';
  static const name = 'name';

  /// Landing screen once logged in. PP-GRP-01 onboarding replaces its builder.
  static const home = 'home';
}

const _restorePath = '/memuat';
const _loginPath = '/masuk';
const _otpPath = '/masuk/kode';
const _namePath = '/nama';
const _homePath = '/';

/// The router, driven by [auth]: whatever the URL, the user lands on the screen
/// their [AuthStatus] allows, and moves on when it changes (login, logout, expired
/// session).
GoRouter createRouter(AuthController auth) {
  return GoRouter(
    initialLocation: _homePath,
    refreshListenable: auth,
    redirect: (context, state) => _redirect(auth, state.matchedLocation),
    routes: [
      GoRoute(
        path: _homePath,
        name: AppRoutes.home,
        builder: (context, state) => const PlaceholderScreen(),
      ),
      sessionRoute(),
      GoRoute(
        path: _restorePath,
        name: AppRoutes.restore,
        builder: (context, state) => const RestoreScreen(),
      ),
      GoRoute(
        path: _loginPath,
        name: AppRoutes.login,
        builder: (context, state) => const LoginScreen(),
        routes: [
          GoRoute(
            path: 'kode',
            name: AppRoutes.otp,
            builder: (context, state) => const OtpScreen(),
          ),
        ],
      ),
      GoRoute(
        path: _namePath,
        name: AppRoutes.name,
        builder: (context, state) => const NameScreen(),
      ),
      ...kasRoutes(),
    ],
  );
}

String? _redirect(AuthController auth, String location) {
  final target = switch (auth.status) {
    AuthStatus.restoring || AuthStatus.restoreFailed => _restorePath,
    AuthStatus.needsName => _namePath,
    AuthStatus.signedOut =>
      location == _otpPath && auth.pendingPhone != null ? _otpPath : _loginPath,
    AuthStatus.signedIn =>
      const [_restorePath, _loginPath, _otpPath, _namePath].contains(location)
          ? _homePath
          : location,
  };
  return target == location ? null : target;
}
