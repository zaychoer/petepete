import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../auth/auth_controller.dart';
import '../ui/theme.dart';
import 'app_scope.dart';
import 'router.dart';

/// Root widget. Takes its services so tests can hand it a fake API and an
/// in-memory token store; `main()` passes the real ones.
class PetepeteApp extends StatefulWidget {
  const PetepeteApp({super.key, required this.api, required this.auth});

  final ApiClient api;
  final AuthController auth;

  @override
  State<PetepeteApp> createState() => _PetepeteAppState();
}

class _PetepeteAppState extends State<PetepeteApp> {
  late final GoRouter _router = createRouter(widget.auth);

  @override
  void initState() {
    super.initState();
    widget.auth.restore();
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      api: widget.api,
      auth: widget.auth,
      child: MaterialApp.router(
        title: 'Petepete',
        theme: buildAppTheme(),
        routerConfig: _router,
      ),
    );
  }
}
