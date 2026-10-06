import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../app/router.dart';
import '../../auth/phone.dart';
import '../../ui/inline_error.dart';

/// Step 1 of login: phone number in, one-time code requested.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  String? get _normalized => normalizePhone(_controller.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final phone = _normalized;
    if (phone == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.of(context).auth.requestOtp(phone);
      if (mounted) context.goNamed(AppRoutes.otp);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final phone = _normalized;
    final typed = _controller.text.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              Text('Masuk ke Petepete', style: textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Masukkan nomor WhatsApp-mu. Kami kirim kode 6 digit ke sana.',
                style: textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.telephoneNumber],
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s().]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Nomor WhatsApp',
                  hintText: '0812-3456-7890',
                ),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              if (phone != null)
                Text(
                  'Kode dikirim ke ${formatPhoneForDisplay(phone)}',
                  style: textTheme.bodyMedium,
                )
              else if (typed)
                Text(
                  'Nomornya belum lengkap. Contoh: 0812-3456-7890',
                  style: textTheme.bodyMedium,
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                InlineError(_error!),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: phone == null || _busy ? null : _submit,
                child: _busy
                    ? const _ButtonSpinner()
                    : const Text('Kirim kode'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 20,
    height: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
