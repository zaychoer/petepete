import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../app/router.dart';
import '../../auth/phone.dart';
import '../../ui/inline_error.dart';

/// Step 2 of login: the 6-digit code, with a resend that waits [resendCooldown]
/// between sends. The server's own limit (5 per hour) comes back as an error.
class OtpScreen extends StatefulWidget {
  const OtpScreen({
    super.key,
    this.resendCooldown = const Duration(seconds: 30),
  });

  final Duration resendCooldown;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  static const _codeLength = 6;

  final _controller = TextEditingController();
  Timer? _timer;
  int _secondsLeft = 0;
  bool _busy = false;
  String? _error;
  bool _resent = false;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _timer?.cancel();
    _secondsLeft = widget.resendCooldown.inSeconds;
    if (_secondsLeft == 0) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) timer.cancel();
    });
  }

  Future<void> _verify() async {
    final code = _controller.text;
    if (code.length != _codeLength || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _resent = false;
    });
    try {
      // On success the router moves on (name step or home).
      await AppScope.of(context).auth.verifyOtp(code);
    } on ApiError catch (e) {
      if (!mounted) return;
      _controller.clear();
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    final auth = AppScope.of(context).auth;
    final phone = auth.pendingPhone;
    if (phone == null || _busy || _secondsLeft > 0) return;
    setState(() {
      _busy = true;
      _error = null;
      _resent = false;
    });
    try {
      await auth.requestOtp(phone);
      if (mounted) setState(() => _resent = true);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _startCooldown();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final auth = AppScope.of(context).auth;
    final phone = auth.pendingPhone;
    final canResend = !_busy && _secondsLeft <= 0;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Masukkan kode', style: textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                phone == null
                    ? 'Kode 6 digit dikirim lewat WhatsApp.'
                    : 'Kode 6 digit dikirim lewat WhatsApp ke ${formatPhoneForDisplay(phone)}. Kode berlaku 5 menit.',
                style: textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: _codeLength,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: textTheme.headlineSmall?.copyWith(letterSpacing: 8),
                decoration: const InputDecoration(labelText: 'Kode 6 digit'),
                onChanged: (value) {
                  setState(() => _error = null);
                  if (value.length == _codeLength) _verify();
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 4),
                InlineError(_error!),
              ],
              if (_resent) ...[
                const SizedBox(height: 4),
                Text('Kode baru sudah dikirim.', style: textTheme.bodyMedium),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _controller.text.length == _codeLength && !_busy
                    ? _verify
                    : null,
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Masuk'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: canResend ? _resend : null,
                child: Text(
                  _secondsLeft > 0
                      ? 'Kirim ulang kode ($_secondsLeft dtk)'
                      : 'Kirim ulang kode',
                ),
              ),
              TextButton(
                onPressed: () => context.goNamed(AppRoutes.login),
                child: const Text('Ganti nomor'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
