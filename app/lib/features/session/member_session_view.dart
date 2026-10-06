import 'package:flutter/material.dart';

import '../../ui/inline_error.dart';
import '../../ui/rupiah.dart';
import 'session_api.dart';
import 'session_models.dart';
import 'session_totals.dart';
import 'weight.dart';

/// What a plain member sees of a session: read-only, and only through calls the API
/// allows members (`GET /api/sessions/:id` and `.../share/summary`). No cost entry,
/// attendance switches, bills, cash actions or sharing: the server answers those with
/// 403 for anyone but the host.
///
/// A draft lists the costs and who attends. An issued session shows the group
/// summary text (per-person amounts and Lunas / Belum bayar, no pay links).
class MemberSessionView extends StatefulWidget {
  const MemberSessionView({
    super.key,
    required this.api,
    required this.detail,
    required this.roster,
  });

  final SessionApi api;
  final SessionDetail detail;
  final GroupRoster roster;

  @override
  State<MemberSessionView> createState() => _MemberSessionViewState();
}

class _MemberSessionViewState extends State<MemberSessionView> {
  SummaryShare? _summary;
  String? _error;

  bool get _issued => widget.detail.status == 'issued';

  @override
  void initState() {
    super.initState();
    if (_issued) _loadSummary();
  }

  Future<void> _loadSummary() async {
    setState(() => _error = null);
    try {
      final summary = await widget.api.summary(widget.detail.id);
      if (mounted) setState(() => _summary = summary);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (detail.isDraft)
          ..._draft(context, detail)
        else
          ..._issuedOrCancelled(),
      ],
    );
  }

  List<Widget> _draft(BuildContext context, SessionDetail detail) {
    final theme = Theme.of(context);
    return [
      SessionTotals(
        detail: detail,
        note:
            'Perkiraan rata-rata, dibagi rata. Angka pasti keluar waktu host mengirim tagihan.',
      ),
      Text('Biaya', style: theme.textTheme.titleMedium),
      if (detail.costItems.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Host belum mengisi biaya.'),
        ),
      for (final item in detail.costItems) _costTile(item),
      const SizedBox(height: 16),
      Text('Kehadiran', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      for (final m in widget.roster.members) _attendanceRow(m, detail),
    ];
  }

  Widget _costTile(CostItem item) {
    final payer = item.paidByName ?? 'host';
    final subset = item.isSubset
        ? ' · Hanya untuk ${item.members.map(widget.roster.nameOf).join(', ')}'
        : '';
    return ListTile(
      key: Key('cost-${item.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(item.label),
      subtitle: Text('Dibayar oleh $payer$subset'),
      trailing: Text(formatRupiah(item.amount)),
    );
  }

  Widget _attendanceRow(RosterMember m, SessionDetail detail) {
    final p = detail.participant(m.id);
    final attended = p?.attended ?? false;
    final name = m.isGuest ? '${m.displayName} (tamu)' : m.displayName;
    return Padding(
      key: Key('attendance-${m.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(name)),
          if (attended) Text(formatWeight(p!.weight)),
          const SizedBox(width: 12),
          Text(attended ? 'Hadir' : 'Tidak'),
        ],
      ),
    );
  }

  List<Widget> _issuedOrCancelled() {
    if (!_issued) {
      return const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Text('Sesi ini dibatalkan, tidak ada tagihan.'),
        ),
      ];
    }
    final summary = _summary;
    if (_error != null) {
      return [
        InlineError(_error!),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('summary-retry'),
          onPressed: _loadSummary,
          child: const Text('Coba lagi'),
        ),
      ];
    }
    if (summary == null) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(summary.text, key: const Key('summary-text')),
        ),
      ),
    ];
  }
}
