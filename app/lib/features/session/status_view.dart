import 'package:flutter/material.dart';

import '../../api/idempotency_key.dart';
import '../../ui/inline_error.dart';
import '../../ui/rupiah.dart';
import '../../ui/status_chip.dart';
import 'link_launcher.dart';
import 'session_api.dart';
import 'session_models.dart';

/// The personal WhatsApp link of a bill: `https://wa.me/<number>?text=<text>` when
/// the member has a number, otherwise the number-less link that opens the chat
/// picker, which is how the text goes to the group chat.
Uri billShareUri(ShareEntry e) {
  final number = e.waNumber;
  if (e.hasPhone && number != null && number.isNotEmpty) {
    return Uri(
      scheme: 'https',
      host: 'wa.me',
      path: '/$number',
      query: 'text=${Uri.encodeComponent(e.text)}',
    );
  }
  return Uri.parse(e.shareUrl);
}

/// Status sesi for an issued (or cancelled) session: every bill with a status chip
/// that carries its text, cash actions, the list that needs checking, WhatsApp
/// sharing and Batalkan tagihan.
class StatusView extends StatefulWidget {
  const StatusView({
    super.key,
    required this.api,
    required this.detail,
    required this.roster,
    required this.launcher,
    required this.onChanged,
  });

  final SessionApi api;
  final SessionDetail detail;
  final GroupRoster roster;
  final LinkLauncher launcher;

  /// Called after a change the parent must reload (a bill's status, a void).
  final Future<void> Function() onChanged;

  @override
  State<StatusView> createState() => _StatusViewState();
}

class _StatusViewState extends State<StatusView> {
  List<ShareEntry>? _bills;
  String? _error;
  final _keys = <String, String>{};

  /// The key of an action stays the same until it succeeds, so a retry after a
  /// failure posts one txn at most.
  String _key(String action) => _keys.putIfAbsent(action, newIdempotencyKey);

  bool get _issued => widget.detail.status == 'issued';

  @override
  void initState() {
    super.initState();
    if (_issued) _loadBills();
  }

  Future<void> _loadBills() async {
    try {
      final bills = await widget.api.shareBills(widget.detail.id);
      if (mounted) {
        setState(() {
          _bills = bills;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _afterChange() async {
    await _loadBills();
    await widget.onChanged();
  }

  Future<void> _open(Uri uri) async {
    final ok = await widget.launcher.open(uri);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'WhatsApp tidak bisa dibuka. Pastikan WhatsApp terpasang.',
          ),
        ),
      );
    }
  }

  Future<void> _markPaid(ShareEntry bill) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _ActionDialog(
        title: 'Tandai lunas',
        body:
            '${bill.displayName} bayar ${formatRupiah(bill.amountDue)} secara cash? '
            'Ini dicatat sebagai uang cash yang kamu terima.',
        confirmLabel: 'Tandai lunas',
        submit: (_) => widget.api.markPaidCash(
          bill.billId,
          idempotencyKey: _key('cash-${bill.billId}'),
        ),
      ),
    );
    if (done == true) {
      _keys.remove('cash-${bill.billId}');
      await _afterChange();
    }
  }

  Future<void> _cancelCash(ShareEntry bill) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _ActionDialog(
        title: 'Batalkan lunas cash',
        body:
            'Pelunasan cash ${bill.displayName} (${formatRupiah(bill.amountDue)}) dibatalkan dan '
            'tagihannya kembali jadi Belum bayar. Hanya bisa dalam 24 jam setelah ditandai lunas.',
        confirmLabel: 'Batalkan lunas',
        reasonLabel: 'Alasan',
        submit: (reason) => widget.api.cancelCash(
          bill.billId,
          reason: reason!,
          idempotencyKey: _key('cancel-cash-${bill.billId}'),
        ),
      ),
    );
    if (done == true) {
      _keys.remove('cancel-cash-${bill.billId}');
      await _afterChange();
    }
  }

  Future<void> _voidIssue() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _ActionDialog(
        title: 'Batalkan tagihan',
        body:
            'Semua tagihan sesi ini dibatalkan dan link bayarnya menampilkan "Tagihan dibatalkan". '
            'Uang yang sudah dibayar tidak hilang: jadi kredit peserta dan otomatis dipakai di tagihan berikutnya. '
            'Setelah itu kamu bisa ubah biaya atau kehadiran, lalu kirim tagihan lagi.',
        confirmLabel: 'Batalkan tagihan',
        reasonLabel: 'Alasan pembatalan',
        submit: (reason) => widget.api.void_(
          widget.detail.id,
          reason: reason!,
          idempotencyKey: _key('void'),
        ),
      ),
    );
    if (done == true) {
      _keys.remove('void');
      await widget.onChanged();
    }
  }

  Future<void> _shareBills() async {
    final bills = _bills ?? await widget.api.shareBills(widget.detail.id);
    if (!mounted) return;
    await _shareSheet(
      title: 'Bagikan tagihan',
      entries: [
        for (final b in bills)
          if (!b.isVoid) b,
      ],
      groupAction: null,
    );
  }

  Future<void> _shareReminder() async {
    try {
      final reminder = await widget.api.reminder(widget.detail.id);
      if (!mounted) return;
      if (reminder.count == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Semua tagihan sudah lunas. Tidak ada yang perlu diingatkan.',
            ),
          ),
        );
        return;
      }
      await _shareSheet(
        title: 'Kirim pengingat (${reminder.count} belum lunas)',
        entries: reminder.entries,
        groupAction: reminder.shareUrl == null
            ? null
            : ('Kirim pengingat ke grup', Uri.parse(reminder.shareUrl!)),
      );
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _shareSummary() async {
    try {
      final summary = await widget.api.summary(widget.detail.id);
      await _open(Uri.parse(summary.shareUrl));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _shareSheet({
    required String title,
    required List<ShareEntry> entries,
    required (String, Uri)? groupAction,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(sheetContext).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (groupAction != null)
              FilledButton.icon(
                key: const Key('share-group'),
                onPressed: () => _open(groupAction.$2),
                icon: const Icon(Icons.groups_outlined),
                label: Text(groupAction.$1),
              ),
            for (final e in entries)
              Padding(
                key: Key('share-${e.billId}'),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.displayName),
                          Text(
                            e.hasPhone
                                ? '${formatRupiah(e.amountDue)} · kirim langsung ke WhatsApp-nya'
                                : '${formatRupiah(e.amountDue)} · belum ada nomor, kirim lewat grup',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () => _open(billShareUri(e)),
                      child: Text(e.hasPhone ? 'Kirim WA' : 'Kirim ke grup'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = widget.detail;
    final bills = _bills;
    final review = [...?bills?.where((b) => b.status == 'needs_review')];
    // Void bills of an earlier issue are listed as Dibatalkan; sharing and
    // Batalkan tagihan only make sense while a live bill exists.
    final hasLiveBills = bills?.any((b) => !b.isVoid) ?? false;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            title: const Text('Total biaya'),
            trailing: Text(
              formatRupiah(detail.totalCost),
              key: const Key('status-total'),
              style: theme.textTheme.titleLarge,
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          InlineError(_error!),
        ],
        if (!_issued)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Sesi ini dibatalkan, tidak ada tagihan.'),
          )
        else if (bills == null && _error == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (bills != null) ...[
          if (review.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Perlu dicek (${review.length})',
              style: theme.textTheme.titleMedium,
            ),
            const Text(
              'Pembayarannya tidak cocok dengan tagihan. Cek uangnya, lalu Tandai lunas kalau sudah benar.',
            ),
            for (final b in review) _billTile(b, keyPrefix: 'review'),
          ],
          const SizedBox(height: 16),
          Text('Tagihan', style: theme.textTheme.titleMedium),
          for (final b in bills) _billTile(b, keyPrefix: 'bill'),
          if (hasLiveBills) ..._shareAndVoid(theme),
        ],
      ],
    );
  }

  List<Widget> _shareAndVoid(ThemeData theme) => [
    const SizedBox(height: 16),
    Text('Bagikan ke WhatsApp', style: theme.textTheme.titleMedium),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          key: const Key('share-bills'),
          onPressed: _shareBills,
          icon: const Icon(Icons.share_outlined),
          label: const Text('Bagikan tagihan'),
        ),
        OutlinedButton(
          key: const Key('share-reminder'),
          onPressed: _shareReminder,
          child: const Text('Kirim pengingat'),
        ),
        OutlinedButton(
          key: const Key('share-summary'),
          onPressed: _shareSummary,
          child: const Text('Kirim ringkasan'),
        ),
      ],
    ),
    const SizedBox(height: 24),
    OutlinedButton(
      key: const Key('void-issue'),
      onPressed: _voidIssue,
      child: const Text('Batalkan tagihan'),
    ),
  ];

  Widget _billTile(ShareEntry b, {required String keyPrefix}) {
    final canMarkPaid = b.status == 'unpaid' || b.status == 'needs_review';
    return Padding(
      key: Key('$keyPrefix-${b.billId}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text(b.displayName), Text(formatRupiah(b.amountDue))],
            ),
          ),
          StatusChip.bill(b.status),
          if (canMarkPaid)
            TextButton(
              key: Key('$keyPrefix-paid-${b.billId}'),
              onPressed: () => _markPaid(b),
              child: const Text('Tandai lunas'),
            ),
          if (b.status == 'paid' && b.cashCancellable)
            TextButton(
              key: Key('$keyPrefix-cancel-${b.billId}'),
              onPressed: () => _cancelCash(b),
              child: const Text('Batal cash'),
            ),
        ],
      ),
    );
  }
}

/// A confirm dialog that runs [submit] itself: a failure shows its message inside
/// the dialog and keeps it open, so the host can retry. With [reasonLabel] the
/// host must type a reason first.
class _ActionDialog extends StatefulWidget {
  const _ActionDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
    required this.submit,
    this.reasonLabel,
  });

  final String title;
  final String body;
  final String confirmLabel;
  final String? reasonLabel;
  final Future<void> Function(String? reason) submit;

  @override
  State<_ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<_ActionDialog> {
  final _reason = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final reason = _reason.text.trim();
    if (widget.reasonLabel != null && reason.isEmpty) {
      setState(() => _error = 'Alasan wajib diisi.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.submit(widget.reasonLabel == null ? null : reason);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.body),
            if (widget.reasonLabel != null) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('reason-input'),
                controller: _reason,
                decoration: InputDecoration(labelText: widget.reasonLabel),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              InlineError(_error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Kembali'),
        ),
        FilledButton(
          key: const Key('action-confirm'),
          onPressed: _busy ? null : _confirm,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
