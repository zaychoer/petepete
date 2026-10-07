import 'package:go_router/go_router.dart';

import '../auth/auth_controller.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/name_screen.dart';
import '../features/auth/otp_screen.dart';
import '../features/auth/restore_screen.dart';
import '../features/groups/group_paths.dart';
import '../features/groups/group_routes.dart';
import '../features/groups/landing_screen.dart';
import '../features/kas/kas_routes.dart';
import '../features/session/session_routes.dart';

/// Route names; navigate with `context.goNamed(AppRoutes.home)`. Later tickets add
/// their names here, under [home] (e.g. a group is `/grup/:groupId`).
abstract final class AppRoutes {
  static const restore = 'restore';
  static const login = 'login';
  static const otp = 'otp';
  static const name = 'name';

  /// Landing screen once logged in: onboarding for a new host, else the group home.
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
  // An invite link opened while signed out: login comes first, then the link.
  String? returnTo;
  return GoRouter(
    initialLocation: _homePath,
    refreshListenable: auth,
    redirect: (context, state) {
      final deepLink = customSchemeJoinLocation(state.uri);
      final location = deepLink?.path ?? state.matchedLocation;
      final target = _redirect(auth, location);
      if (auth.status != AuthStatus.signedIn &&
          location.startsWith(GroupRoutes.joinPrefix)) {
        returnTo = (deepLink ?? state.uri).toString();
      } else if (target == _homePath &&
          auth.status == AuthStatus.signedIn &&
          returnTo != null) {
        final back = returnTo;
        returnTo = null;
        return back;
      }
      return target ?? deepLink?.toString();
    },
    routes: [
      GoRoute(
        path: _homePath,
        name: AppRoutes.home,
        builder: (context, state) => const LandingScreen(),
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
      ...groupRoutes,
    ],
  );
}

/// The custom scheme of the web-to-app handoff: `petepete://join/<token>?claim=<id>`.
const _customScheme = 'petepete';

/// The in-app location of a `petepete://join/<token>?claim=<id>` link, or null for
/// any other URI. In that form `join` is the URI host and the token the path, which
/// no route matches, so the router rewrites it to `/join/<token>?claim=<id>`, the
/// same location the https invite link (`https://<host>/join/<token>`) already has.
Uri? customSchemeJoinLocation(Uri uri) {
  if (uri.scheme != _customScheme || uri.host != 'join') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 1) return null;
  return Uri(
    path: '${GroupRoutes.joinPrefix}${segments.single}',
    queryParameters: uri.hasQuery ? uri.queryParameters : null,
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
