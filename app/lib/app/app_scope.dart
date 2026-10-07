import 'package:flutter/widgets.dart';

import '../api/api_client.dart';
import '../auth/auth_controller.dart';

/// The app's shared services, reachable from any screen:
/// `AppScope.of(context).api` for HTTP calls, `.auth` for login state.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.api,
    required this.auth,
    required super.child,
  });

  final ApiClient api;
  final AuthController auth;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this context');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      api != oldWidget.api || auth != oldWidget.auth;
}
