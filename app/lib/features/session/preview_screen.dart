import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../api/idempotency_key.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import '../../ui/rupiah.dart';
import 'session_api.dart';
import 'session_models.dart';
import 'weight.dart';

/// The bill preview: per person per cost item, total billed vs total cost, credit
/// used and "Masuk kas". It is the server's `GET /api/sessions/:id/preview`, the
/// same calculation that issues the bills, so the numbers here are the bills'.
///
/// When the session cannot be billed the server's `problems` are shown in words
/// and the Kirim tagihan button is not offered.
class PreviewScreen extends StatefulWidget {
  const PreviewScreen({
    super.key,
    required this.groupId,
    required this.sessionId,
  });

  final int groupId;
  final int sessionId;

  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  SessionApi? _api;
  GroupRoster? _roster;
  SessionDetail? _detail;
  Preview? _preview;
  List<String> _problems = const [];
  String? _error;
  String? _sendError;
  bool _sending = false;

  /// One key for this issue action: a retry after a dropped connection reuses it,
  /// so the API posts a single txn.
  String? _issueKey;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_api == null) {
      _api = SessionApi(AppScope.of(context).api);
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _problems = const [];
    });
    try {
      final roster = await _api!.roster(widget.groupId);
      final detail = await _api!.session(widget.sessionId);
      if (!mounted) return;
      _roster = roster;
      _detail = detail;
      final preview = await _api!.preview(widget.sessionId);
      if (mounted) setState(() => _preview = preview);
    } on ApiError catch (e) {
      if (!mounted) return;
      if (e.code == 'invalid_session' && e.details is List) {
        setState(() => _problems = _describeProblems(e.details as List));
      } else {
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  List<String> _describeProblems(List problems) {
    String itemName(Object? id) {
      for (final i in _detail?.costItems ?? const <CostItem>[]) {
        if (i.id == id) return i.label;
      }
      return 'pos biaya';
    }

    return [
      for (final p in problems)
        switch ((p as Map)['code']) {
          'item_without_bearers' =>
            'Pos "${itemName(p['id'])}" belum ada peserta hadir yang menanggung. Centang kehadiran atau ubah "Hanya untuk…".',
          'item_without_payer' =>
            'Pos "${itemName(p['id'])}" belum ada yang menalangi. Pilih penalangnya.',
          'invalid_amount' =>
            'Nominal pos "${itemName(p['id'])}" harus lebih dari Rp0.',
          'invalid_weight' =>
            'Ada peserta dengan bobot tidak valid. Bobot harus lebih dari 0.',
          'total_cost_not_positive' =>
            'Total biaya harus lebih dari Rp0. Tambah pos biaya dulu.',
          final code => 'Masalah di sesi ini: $code.',
        },
    ];
  }

  Future<void> _issue() async {
    final key = _issueKey ??= newIdempotencyKey();
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      await _api!.issue(widget.sessionId, idempotencyKey: key);
      if (mounted) context.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _sendError = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Pratinjau tagihan')),
      body: SafeArea(
        child: preview != null
            ? _content(preview)
            : _problems.isNotEmpty
            ? _blocked()
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InlineError(_error!),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _load,
                        child: const Text('Coba lagi'),
                      ),
                    ],
                  ),
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _blocked() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Tagihan belum bisa dikirim',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        for (final p in _problems)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InlineError(p),
          ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => context.pop(),
          child: const Text('Kembali dan perbaiki'),
        ),
      ],
    );
  }

  Widget _content(Preview p) {
    final theme = Theme.of(context);
    final roster = _roster!;
    String payerOf(PreviewItem i) =>
        i.paidByMemberId == null ? '-' : roster.nameOf(i.paidByMemberId!);
    final itemsById = {for (final i in p.items) i.id: i};
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _row(
                  'Total biaya',
                  formatRupiah(p.totalCost),
                  key: 'total-cost',
                ),
                _row(
                  'Total ditagih',
                  formatRupiah(p.totalBilled),
                  key: 'total-billed',
                ),
                _row(
                  'Kredit terpakai',
                  formatRupiah(p.creditUsed),
                  key: 'credit-used',
                ),
                _row(
                  'Yang harus dibayar peserta',
                  formatRupiah(p.totalDue),
                  key: 'total-due',
                ),
                _row(
                  'Masuk kas',
                  formatRupiah(p.kasRemainder),
                  key: 'kas-remainder',
                  label: 'Masuk kas: ${formatRupiah(p.kasRemainder)}',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text('Pos biaya', style: theme.textTheme.titleMedium),
        for (final i in p.items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(i.label),
            subtitle: Text('Ditalangi ${payerOf(i)}'),
            trailing: Text(formatRupiah(i.amount)),
          ),
        const SizedBox(height: 8),
        Text('Per orang', style: theme.textTheme.titleMedium),
        for (final m in p.members)
          Card(
            key: Key('member-${m.memberId}'),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.weight == 1000
                        ? m.displayName
                        : '${m.displayName} (${formatWeight(m.weight)})',
                    style: theme.textTheme.titleSmall,
                  ),
                  for (final l in m.lines)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            itemsById[l.costItemId] == null
                                ? l.label
                                : '${l.label} (talangan ${payerOf(itemsById[l.costItemId]!)})',
                          ),
                        ),
                        Text(formatRupiah(l.amount)),
                      ],
                    ),
                  if (m.rounding != 0)
                    Row(
                      children: [
                        const Expanded(child: Text('Pembulatan')),
                        Text(formatRupiah(m.rounding)),
                      ],
                    ),
                  const Divider(),
                  Row(
                    children: [
                      const Expanded(child: Text('Bagian')),
                      Text(formatRupiah(m.share)),
                    ],
                  ),
                  if (m.creditApplied > 0)
                    Row(
                      children: [
                        const Expanded(child: Text('Kredit terpakai')),
                        Text('-${formatRupiah(m.creditApplied)}'),
                      ],
                    ),
                  Row(
                    children: [
                      const Expanded(child: Text('Harus bayar')),
                      Text(
                        formatRupiah(m.amountDue),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (_sendError != null) ...[
          InlineError(_sendError!),
          const SizedBox(height: 8),
        ],
        FilledButton(
          key: const Key('issue-button'),
          onPressed: _sending ? null : _issue,
          child: Text(_sending ? 'Mengirim…' : 'Kirim tagihan'),
        ),
      ],
    );
  }

  Widget _row(String name, String value, {required String key, String? label}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label ?? name, key: label == null ? null : Key(key)),
          ),
          if (label == null) Text(value, key: Key(key)),
        ],
      ),
    );
  }
}
