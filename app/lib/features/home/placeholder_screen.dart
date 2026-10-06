import 'package:flutter/material.dart';

import '../../app/app_scope.dart';

/// Landing screen after login. This is the one place PP-GRP-01 onboarding plugs in:
/// replace the builder of `AppRoutes.home` in `app/router.dart`.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final auth = AppScope.of(context).auth;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Petepete', style: textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Patungan olahraga tanpa ribet. Aplikasinya lagi disiapin, sabar ya!',
                style: textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              ListenableBuilder(
                listenable: auth,
                builder: (context, _) => Text(
                  'Halo, ${auth.user?.displayName ?? ''}!',
                  style: textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: auth.logout, child: const Text('Keluar')),
            ],
          ),
        ),
      ),
    );
  }
}
