import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/date_format.dart';
import '../../ui/rupiah.dart';
import 'correction_dialog.dart';
import 'kas_api.dart';
import 'kas_models.dart';
import 'kas_routes.dart';
import 'kas_widgets.dart';

/// How a member's balance reads, always in words: negative owes the group,
/// positive is credit.
String balanceWords(int balance) {
  if (balance < 0) return 'Berutang ${formatRupiah(-balance)}';
  if (balance > 0) return 'Kredit ${formatRupiah(balance)}';
  return 'Impas (Rp0)';
}

/// Kas & riwayat: the kas balance, every member's balance, and the group's ledger
/// history in casual Indonesian. Every member can read it; the host also gets the
/// entry buttons and "Koreksi".
class KasScreen extends StatefulWidget {
  const KasScreen({super.key, required this.groupId});

  final int groupId;

  @override
  State<KasScreen> createState() => _KasScreenState();
}

class _KasScreenState extends State<KasScreen> {
  KasApi? _kas;
  KasGroup? _group;
  KasBalances? _balances;
  List<KasTxn>? _txns;
  int? _filterMemberId;
  String? _error;
  String? _txnsError;
  bool _loading = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_kas == null) {
      _kas = KasApi(AppScope.of(context).api);
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object>([
        _kas!.group(widget.groupId),
        _kas!.balances(widget.groupId),
        _kas!.txns(widget.groupId, memberId: _filterMemberId),
      ]);
      if (!mounted) return;
      setState(() {
        _group = results[0] as KasGroup;
        _balances = results[1] as KasBalances;
        _txns = results[2] as List<KasTxn>;
        _txnsError = null;
        _loading = false;
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  Future<void> _filter(int? memberId) async {
    setState(() {
      _filterMemberId = memberId;
      _txnsError = null;
    });
    try {
      final txns = await _kas!.txns(widget.groupId, memberId: memberId);
      if (!mounted || _filterMemberId != memberId) return;
      setState(() => _txns = txns);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _txnsError = e.message);
    }
  }

  Future<void> _open(String routeName) async {
    final done = await context.pushNamed<bool>(
      routeName,
      pathParameters: {'groupId': '${widget.groupId}'},
    );
    if (done == true && mounted) await _load();
  }

  Future<void> _correct(KasTxn txn) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => CorrectionDialog(txn: txn),
    );
    if (done == true && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kas & riwayat')),
      body: SafeArea(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _balances == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _balances == null) {
      return LoadErrorView(message: _error!, onRetry: _load);
    }
    final balances = _balances!;
    final group = _group!;
    final txns = _txns ?? const <KasTxn>[];
    final reversed = {
      for (final t in txns)
        if (t.reversesTxnId != null) t.reversesTxnId!,
    };
    final textTheme = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _KasCard(kas: balances.kas),
          if (group.isHost) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => _open(KasRoutes.settlement),
                  child: const Text('Catat pelunasan'),
                ),
                FilledButton.tonal(
                  onPressed: () => _open(KasRoutes.spend),
                  child: const Text('Belanja dari kas'),
                ),
                FilledButton.tonal(
                  onPressed: () => _open(KasRoutes.withdraw),
                  child: const Text('Tarik dana'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text('Saldo anggota', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final m in balances.members) _MemberBalanceTile(member: m),
          const SizedBox(height: 24),
          Text('Riwayat', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          DropdownButtonFormField<int?>(
            key: const Key('filter-member'),
            initialValue: _filterMemberId,
            decoration: const InputDecoration(labelText: 'Filter anggota'),
            items: [
              const DropdownMenuItem<int?>(
                value: null,
                child: Text('Semua anggota'),
              ),
              for (final m in balances.members)
                DropdownMenuItem<int?>(
                  value: m.memberId,
                  child: Text(m.displayName),
                ),
            ],
            onChanged: _filter,
          ),
          const SizedBox(height: 8),
          if (_txnsError != null) ...[
            LoadErrorView(
              message: _txnsError!,
              onRetry: () => _filter(_filterMemberId),
            ),
          ] else if (txns.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                _filterMemberId == null
                    ? 'Belum ada catatan. Nanti semua uang masuk dan keluar muncul di sini.'
                    : 'Belum ada catatan untuk anggota ini.',
                textAlign: TextAlign.center,
              ),
            )
          else
            for (final t in txns)
              _TxnTile(
                txn: t,
                reversed: reversed.contains(t.id),
                canCorrect: group.isHost,
                onCorrect: () => _correct(t),
              ),
        ],
      ),
    );
  }
}

class _KasCard extends StatelessWidget {
  const _KasCard({required this.kas});

  final int kas;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Saldo kas', style: textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(formatRupiah(kas), style: textTheme.headlineMedium),
            if (kas < 0) ...[
              const SizedBox(height: 4),
              Text(
                'Kas lagi minus, belum bisa dipakai belanja.',
                style: textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemberBalanceTile extends StatelessWidget {
  const _MemberBalanceTile({required this.member});

  final MemberBalance member;

  @override
  Widget build(BuildContext context) {
    final b = member.balance;
    final icon = b < 0
        ? Icons.arrow_downward
        : b > 0
        ? Icons.arrow_upward
        : Icons.check;
    return ListTile(
      key: Key('balance-${member.memberId}'),
      contentPadding: EdgeInsets.zero,
      title: Text(member.displayName),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 18)),
          const SizedBox(width: 6),
          Text(balanceWords(b)),
        ],
      ),
    );
  }
}

class _TxnTile extends StatelessWidget {
  const _TxnTile({
    required this.txn,
    required this.reversed,
    required this.canCorrect,
    required this.onCorrect,
  });

  final KasTxn txn;
  final bool reversed;
  final bool canCorrect;
  final VoidCallback onCorrect;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      key: Key('txn-${txn.id}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(txn.description, style: textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text(formatWaktu(txn.insertedAt), style: textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                kindChip(txn.kind, label: txn.kindLabel),
                if (reversed)
                  const Text('Sudah dikoreksi')
                else if (canCorrect && txn.isCorrectable)
                  TextButton(
                    onPressed: onCorrect,
                    child: const Text('Koreksi'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
