import 'package:flutter/material.dart';

void main() {
  runApp(const PetepeteApp());
}

class PetepeteApp extends StatelessWidget {
  const PetepeteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Petepete',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: const PlaceholderScreen(),
    );
  }
}

/// Shown until onboarding (PP-GRP-01) replaces it.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
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
            ],
          ),
        ),
      ),
    );
  }
}
