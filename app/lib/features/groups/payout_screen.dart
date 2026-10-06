import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../api/idempotency_key.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import '../../ui/status_chip.dart';
import 'async_body.dart';
import 'groups_api.dart';

/// The status of a payout account as a chip with text (never colour alone).
StatusChip payoutStatusChip(PayoutAccountInfo info) => StatusChip(
  label: info.statusLabel,
  tone: switch (info.status) {
    'active' => StatusTone.success,
    'pending_kyc' => StatusTone.warning,
    _ => StatusTone.neutral,
  },
);

String _statusHint(String status) => switch (status) {
  'active' => 'Rekeningmu sudah aktif. Uang patungan bisa dicairkan ke sini.',
  'pending_kyc' =>
    'Verifikasi data rekening sedang diproses. Kamu belum bisa menarik dana sampai statusnya Aktif.',
  _ => '',
};

/// Rekening pencairan: where the group's gateway money is paid out to. Shows the
/// registered account and its status, or the form to register one (host only).
class PayoutScreen extends StatefulWidget {
  const PayoutScreen({super.key, required this.groupId});

  final int groupId;

  @override
  State<PayoutScreen> createState() => _PayoutScreenState();
}

class _PayoutScreenState extends State<PayoutScreen> {
  // Set after a successful registration so the screen switches to the status view
  // without another round trip.
  PayoutAccountInfo? _registered;

  @override
  Widget build(BuildContext context) {
    final api = GroupsApi(AppScope.of(context).api);
    return Scaffold(
      appBar: AppBar(title: const Text('Rekening pencairan')),
      body: _registered != null
          ? _StatusView(info: _registered!)
          : AsyncBody<PayoutAccountInfo?>(
              load: () => api.payoutAccount(widget.groupId),
              builder: (context, info, _) => info != null
                  ? _StatusView(info: info)
                  : _RegisterForm(
                      api: api,
                      groupId: widget.groupId,
                      onRegistered: (info) =>
                          setState(() => _registered = info),
                    ),
            ),
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.info});

  final PayoutAccountInfo info;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Status', style: textTheme.titleMedium),
                const SizedBox(height: 8),
                payoutStatusChip(info),
                const SizedBox(height: 12),
                if (info.bankName != null)
                  Text(
                    '${info.bankName} · •••• ${info.accountLast4 ?? ''}',
                    style: textTheme.titleMedium,
                  ),
                const SizedBox(height: 8),
                Text(_statusHint(info.status)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RegisterForm extends StatefulWidget {
  const _RegisterForm({
    required this.api,
    required this.groupId,
    required this.onRegistered,
  });

  final GroupsApi api;
  final int groupId;
  final void Function(PayoutAccountInfo info) onRegistered;

  @override
  State<_RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<_RegisterForm> {
  final _bank = TextEditingController();
  final _number = TextEditingController();
  final _holder = TextEditingController();
  bool _busy = false;
  List<String> _errors = const [];
  String? _apiError;
  // Created when the registration starts and kept for retries after a failure.
  String? _key;

  @override
  void dispose() {
    _bank.dispose();
    _number.dispose();
    _holder.dispose();
    super.dispose();
  }

  String get _digits => _number.text.replaceAll(RegExp(r'[\s-]'), '');

  List<String> _validate() => [
    if (_bank.text.trim().isEmpty) 'Nama bank harus diisi.',
    if (!RegExp(r'^\d{6,}$').hasMatch(_digits))
      'Nomor rekening harus berupa angka, minimal 6 digit.',
    if (_holder.text.trim().isEmpty) 'Nama pemilik rekening harus diisi.',
  ];

  Future<void> _submit() async {
    if (_busy) return;
    final errors = _validate();
    setState(() {
      _errors = errors;
      _apiError = null;
    });
    if (errors.isNotEmpty) return;
    setState(() => _busy = true);
    final key = _key ??= newIdempotencyKey();
    try {
      final registered = await widget.api.registerPayoutAccount(
        widget.groupId,
        idempotencyKey: key,
        bankName: _bank.text.trim(),
        accountNumber: _digits,
        accountHolderName: _holder.text.trim(),
      );
      widget.onRegistered(registered);
    } on ApiError catch (e) {
      if (mounted) setState(() => _apiError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Daftarkan rekening tempat uang patungan dicairkan. '
          'Kamu sebagai host jadi pemilik rekening ini.',
          style: textTheme.bodyLarge,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _bank,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Bank',
            hintText: 'Contoh: BCA',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _number,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Nomor rekening'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _holder,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Nama pemilik rekening',
            helperText: 'Sesuai nama di buku tabungan.',
          ),
        ),
        const SizedBox(height: 16),
        for (final error in _errors) ...[
          InlineError(error),
          const SizedBox(height: 8),
        ],
        if (_apiError != null) ...[
          InlineError(_apiError!),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: BusyButtonChild(busy: _busy, label: 'Daftarkan rekening'),
        ),
      ],
    );
  }
}
