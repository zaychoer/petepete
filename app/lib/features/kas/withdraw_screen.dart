import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/date_format.dart';
import '../../ui/external_link.dart';
import '../../ui/inline_error.dart';
import '../../ui/rupiah.dart';
import '../../ui/status_chip.dart';
import 'kas_api.dart';
import 'kas_models.dart';
import 'kas_routes.dart';
import 'kas_widgets.dart';

/// Tarik dana: the sub-account balance, a withdrawal to the registered bank account
/// and the withdrawal history. Withdrawals never change the ledger.
///
/// When the gateway only offers its dashboard (a managed sub-account) the server
/// answers with a `managed_url` and [launchUrl] opens it outside the app.
class WithdrawScreen extends StatefulWidget {
  const WithdrawScreen({
    super.key,
    required this.groupId,
    this.launchUrl = openExternally,
  });

  final int groupId;
  final UrlLauncher launchUrl;

  @override
  State<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends State<WithdrawScreen> {
  final _amount = TextEditingController();
  final _key = AttemptKey();
  KasApi? _kas;
  PayoutBalance? _account;
  List<Withdrawal> _history = const [];
  String? _loadError;
  String? _loadErrorCode;
  String? _error;
  String? _notice;
  String? _openFailedUrl;
  bool _loading = true;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_kas == null) {
      _kas = KasApi(AppScope.of(context).api);
      _load();
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _loadErrorCode = null;
    });
    try {
      final results = await Future.wait<Object>([
        _kas!.payoutBalance(widget.groupId),
        _kas!.withdrawals(widget.groupId),
      ]);
      if (!mounted) return;
      setState(() {
        _account = results[0] as PayoutBalance;
        _history = results[1] as List<Withdrawal>;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.message;
        _loadErrorCode = e.code;
        _loading = false;
      });
    }
  }

  void _changed() => setState(() {
    _key.reset();
    _error = null;
    _notice = null;
  });

  int? get _parsed => parseAmount(_amount.text);

  String? get _amountError {
    if (_amount.text.isEmpty) return null;
    final base = amountError(_parsed);
    if (base != null) return base;
    final balance = _account?.balance;
    if (balance != null && _parsed! > balance) {
      return 'Saldo sub-account cuma ${formatRupiah(balance)}.';
    }
    return null;
  }

  bool get _valid =>
      amountError(_parsed) == null && _parsed! <= (_account?.balance ?? 0);

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _openFailedUrl = null;
    });
    final amount = _parsed!;
    try {
      final result = await _kas!.withdraw(
        widget.groupId,
        amount: amount,
        idempotencyKey: _key.current,
      );
      _key.reset();
      _amount.clear();
      final url = result.managedUrl;
      var opened = true;
      if (url != null) opened = await _tryOpen(url);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = url == null
            ? 'Penarikan ${formatRupiah(amount)} diajukan.'
            : 'Penarikan ${formatRupiah(amount)} perlu diselesaikan di dashboard gateway.';
        _openFailedUrl = opened ? null : url;
      });
      await _load();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<bool> _tryOpen(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    try {
      return await widget.launchUrl(uri);
    } on Object {
      return false;
    }
  }

  Future<void> _openDashboard(String url) async {
    final opened = await _tryOpen(url);
    if (!mounted) return;
    setState(() => _openFailedUrl = opened ? null : url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tarik dana')),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _account == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null && _account == null) {
      return Column(
        children: [
          Expanded(
            child: LoadErrorView(message: _loadError!, onRetry: _load),
          ),
          if (_loadErrorCode == 'no_payout_account')
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: () => context.pushNamed(
                  KasRoutes.payoutRegister,
                  pathParameters: {'groupId': '${widget.groupId}'},
                ),
                child: const Text('Daftarkan rekening pencairan'),
              ),
            ),
        ],
      );
    }
    final account = _account!;
    final textTheme = Theme.of(context).textTheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Saldo sub-account', style: textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    formatRupiah(account.balance),
                    style: textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Rekening tujuan: ${_accountLabel(account)}',
                    style: textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (!account.owner)
            const Text(
              'Cuma pemilik rekening pencairan yang bisa menarik dana.',
            )
          else if (!account.canWithdraw)
            const Text(
              'Rekening pencairan belum aktif, jadi belum bisa menarik dana. Selesaikan verifikasinya dulu ya.',
            )
          else ...[
            AmountField(
              controller: _amount,
              label: 'Mau tarik berapa? (Rp)',
              enabled: !_busy,
              errorText: _amountError,
              onChanged: (_) => _changed(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              InlineError(_error!),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _valid && !_busy ? _submit : null,
              child: Text(_busy ? 'Memproses…' : 'Tarik dana'),
            ),
          ],
          if (_notice != null) ...[
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(_notice!)),
          ],
          if (_openFailedUrl != null) ...[
            const SizedBox(height: 8),
            const Text(
              'Dashboard gagal dibuka otomatis. Buka tautan ini di browser:',
            ),
            SelectableText(_openFailedUrl!),
          ],
          const SizedBox(height: 24),
          Text('Riwayat penarikan', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_history.isEmpty)
            const Text('Belum ada penarikan.')
          else
            for (final w in _history)
              _WithdrawalTile(
                withdrawal: w,
                onOpenDashboard: w.managedUrl == null
                    ? null
                    : () => _openDashboard(w.managedUrl!),
              ),
        ],
      ),
    );
  }

  String _accountLabel(PayoutBalance a) {
    final bank = a.bankName ?? 'Rekening';
    final last4 = a.accountLast4;
    return last4 == null ? bank : '$bank ••••$last4';
  }
}

class _WithdrawalTile extends StatelessWidget {
  const _WithdrawalTile({required this.withdrawal, this.onOpenDashboard});

  final Withdrawal withdrawal;
  final VoidCallback? onOpenDashboard;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final tone = switch (withdrawal.status) {
      'failed' => StatusTone.danger,
      'managed' || 'pending' => StatusTone.warning,
      _ => StatusTone.info,
    };
    return Card(
      key: Key('withdrawal-${withdrawal.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(formatRupiah(withdrawal.amount), style: textTheme.titleMedium),
            Text(
              formatWaktu(withdrawal.insertedAt),
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusChip(label: withdrawal.statusLabel, tone: tone),
                if (onOpenDashboard != null)
                  TextButton(
                    onPressed: onOpenDashboard,
                    child: const Text('Buka dashboard'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
