import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../auth/auth_controller.dart';
import '../../ui/inline_error.dart';

/// Shown while the stored session is checked at app start; offers a retry when the
/// server could not be reached.
class RestoreScreen extends StatelessWidget {
  const RestoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AppScope.of(context).auth;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ListenableBuilder(
              listenable: auth,
              builder: (context, _) {
                if (auth.status != AuthStatus.restoreFailed) {
                  return const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Memuat…'),
                    ],
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InlineError(auth.restoreError ?? ''),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: auth.restore,
                      child: const Text('Coba lagi'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
