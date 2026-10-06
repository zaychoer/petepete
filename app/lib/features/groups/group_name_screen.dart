import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'group_paths.dart';

/// Step 1 of onboarding: what is the group called. Hands the name to the template step.
class GroupNameScreen extends StatefulWidget {
  const GroupNameScreen({super.key});

  @override
  State<GroupNameScreen> createState() => _GroupNameScreenState();
}

class _GroupNameScreenState extends State<GroupNameScreen> {
  // The API allows 80 characters.
  static const _maxLength = 80;

  final _controller = TextEditingController();

  bool get _valid => _controller.text.trim().isNotEmpty;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (!_valid) return;
    context.pushNamed(GroupRoutes.template, extra: _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Akun',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => context.pushNamed(GroupRoutes.account),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              Text('Bikin grup pertamamu', style: textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Kasih nama grup patungannya, misalnya nama tim atau geng mainmu.',
                style: textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                maxLength: _maxLength,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Nama grup',
                  hintText: 'Contoh: Futsal Kamis Malam',
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _next(),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _valid ? _next : null,
                child: const Text('Lanjut'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
