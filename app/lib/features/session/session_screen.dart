import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import '../../ui/rupiah.dart';
import '../../ui/status_chip.dart';
import 'cost_sheet.dart';
import 'link_launcher.dart';
import 'member_session_view.dart';
import 'session_api.dart';
import 'session_models.dart';
import 'session_routes.dart';
import 'session_totals.dart';
import 'status_view.dart';
import 'weight.dart';

/// One session. The host of a draft gets the cost entry (category chips, nominal,
/// Simpan), attendance with weights and "Tambah tamu", and the way to the bill preview;
/// once issued, [StatusView]: bills with their status, cash actions, WhatsApp sharing
/// and Batalkan tagihan. A member sees [MemberSessionView] instead, read-only: bills,
/// cash actions and sharing are host-only on the server.
class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.groupId,
    required this.sessionId,
    required this.launcher,
  });

  final int groupId;
  final int sessionId;
  final LinkLauncher launcher;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  SessionApi? _api;
  GroupRoster? _roster;
  SessionDetail? _detail;
  String? _loadError;
  String? _actionError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_api == null) {
      _api = SessionApi(AppScope.of(context).api);
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final roster = await _api!.roster(widget.groupId);
      final detail = await _api!.session(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _roster = roster;
        _detail = detail;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = errorText(e));
    }
  }

  Future<void> _reloadDetail() async {
    try {
      final detail = await _api!.session(widget.sessionId);
      if (mounted) setState(() => _detail = detail);
    } catch (e) {
      if (mounted) setState(() => _actionError = errorText(e));
    }
  }

  /// Runs a host edit; its failure shows under the sections, not as a crash.
  Future<void> _edit(Future<void> Function() action) async {
    setState(() => _actionError = null);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _actionError = errorText(e));
    }
  }

  void _openCostSheet(String category, {CostItem? existing}) {
    showCostSheet(
      context,
      roster: _roster!,
      category: category,
      existing: existing,
      onSave: (draft) async {
        final saved = await _api!.saveCost(
          widget.sessionId,
          costId: existing?.id,
          category: draft.category,
          label: draft.label,
          amount: draft.amount,
          paidBy: draft.paidBy,
          subset: draft.subset,
          members: draft.members,
        );
        if (!mounted) return;
        // The header updates from the saved item right away; the refetch below
        // brings the server's view of who bears each item.
        setState(() {
          _actionError = null;
          _detail = _withItem(_detail!, saved);
        });
        await _reloadDetail();
      },
    );
  }

  SessionDetail _withItem(SessionDetail d, CostItem item) {
    final items = [...d.costItems];
    final at = items.indexWhere((i) => i.id == item.id);
    if (at >= 0) {
      items[at] = item;
    } else {
      items.add(item);
    }
    return SessionDetail(
      id: d.id,
      groupId: d.groupId,
      startsAt: d.startsAt,
      status: d.status,
      progress: d.progress,
      costItems: items,
      participants: d.participants,
    );
  }

  Future<void> _deleteCost(CostItem item) => _edit(() async {
    await _api!.deleteCost(widget.sessionId, item.id);
    await _reloadDetail();
  });

  Future<void> _toggleAttendance(RosterMember m, bool attended) =>
      _edit(() async {
        await _api!.setAttendance(
          widget.sessionId,
          memberId: m.id,
          attended: attended,
        );
        await _reloadDetail();
      });

  Future<void> _editWeight(RosterMember m) async {
    final current = _detail!.participant(m.id)?.weight ?? 1000;
    final weight = await showDialog<int>(
      context: context,
      builder: (_) => _WeightDialog(name: m.displayName, current: current),
    );
    if (weight == null || weight == current) return;
    await _edit(() async {
      await _api!.setAttendance(
        widget.sessionId,
        memberId: m.id,
        weight: weight,
      );
      await _reloadDetail();
    });
  }

  Future<void> _addGuest() async {
    final guest = await showDialog<({String name, String? phone})>(
      context: context,
      builder: (_) => const _GuestDialog(),
    );
    if (guest == null) return;
    await _edit(() async {
      final id = await _api!.addGuest(
        widget.groupId,
        name: guest.name,
        phone: guest.phone,
      );
      await _api!.setAttendance(widget.sessionId, memberId: id, attended: true);
      final roster = await _api!.roster(widget.groupId);
      if (mounted) setState(() => _roster = roster);
      await _reloadDetail();
    });
  }

  Future<void> _openPreview() async {
    await context.pushNamed(
      SessionRoutes.preview,
      pathParameters: {
        'groupId': '${widget.groupId}',
        'sessionId': '${widget.sessionId}',
      },
    );
    if (mounted) await _reloadDetail();
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final roster = _roster;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sesi'),
        actions: [
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: StatusChip.session(
                detail.status,
                settled: detail.progress == 'settled',
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: detail == null || roster == null
            ? _loadError != null
                  ? _LoadFailed(message: _loadError!, onRetry: _load)
                  : const Center(child: CircularProgressIndicator())
            : !roster.isHost
            ? MemberSessionView(api: _api!, detail: detail, roster: roster)
            : detail.isDraft
            ? _draftBody(detail, roster)
            : StatusView(
                api: _api!,
                detail: detail,
                roster: roster,
                launcher: widget.launcher,
                onChanged: _load,
              ),
      ),
    );
  }

  Widget _draftBody(SessionDetail detail, GroupRoster roster) {
    final theme = Theme.of(context);
    final categories = [
      ...roster.categories,
      if (!roster.categories.contains('Lainnya')) 'Lainnya',
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SessionTotals(
          detail: detail,
          note:
              'Perkiraan rata-rata, dibagi rata. Angka pasti (bobot dan pembulatan) ada di pratinjau tagihan.',
        ),
        if (_actionError != null) ...[
          InlineError(_actionError!),
          const SizedBox(height: 8),
        ],
        Text('Biaya', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final c in categories)
              ActionChip(
                key: Key('chip-$c'),
                label: Text(c),
                onPressed: () => _openCostSheet(c),
              ),
          ],
        ),
        for (final item in detail.costItems) _costTile(item, roster),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text('Kehadiran', style: theme.textTheme.titleMedium),
            ),
            TextButton.icon(
              key: const Key('add-guest'),
              onPressed: _addGuest,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Tambah tamu'),
            ),
          ],
        ),
        for (final m in roster.members) _attendanceRow(m, detail),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('open-preview'),
          onPressed: detail.costItems.isEmpty ? null : _openPreview,
          child: const Text('Lihat pratinjau tagihan'),
        ),
      ],
    );
  }

  Widget _costTile(CostItem item, GroupRoster roster) {
    final payer = item.paidByName ?? 'host';
    final subset = item.isSubset
        ? ' · Hanya untuk ${item.members.map(roster.nameOf).join(', ')}'
        : '';
    return Column(
      children: [
        ListTile(
          key: Key('cost-${item.id}'),
          contentPadding: EdgeInsets.zero,
          title: Text(item.label),
          subtitle: Text('Dibayar oleh $payer$subset'),
          onTap: () => _openCostSheet(item.category, existing: item),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(formatRupiah(item.amount)),
              IconButton(
                tooltip: 'Hapus ${item.label}',
                onPressed: () => _deleteCost(item),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        if (item.hasNoBearer)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InlineError(
              'Belum ada peserta hadir yang menanggung "${item.label}". Tagihan belum bisa dikirim.',
            ),
          ),
      ],
    );
  }

  Widget _attendanceRow(RosterMember m, SessionDetail detail) {
    final p = detail.participant(m.id);
    final attended = p?.attended ?? false;
    return Row(
      key: Key('attendance-${m.id}'),
      children: [
        Expanded(
          child: Text(m.isGuest ? '${m.displayName} (tamu)' : m.displayName),
        ),
        TextButton(
          key: Key('weight-${m.id}'),
          onPressed: () => _editWeight(m),
          child: Text(formatWeight(p?.weight ?? 1000)),
        ),
        Switch(
          key: Key('attend-${m.id}'),
          value: attended,
          onChanged: (v) => _toggleAttendance(m, v),
        ),
        Text(attended ? 'Hadir' : 'Tidak'),
      ],
    );
  }
}

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InlineError(message),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Coba lagi')),
          ],
        ),
      ),
    );
  }
}

class _WeightDialog extends StatefulWidget {
  const _WeightDialog({required this.name, required this.current});

  final String name;
  final int current;

  @override
  State<_WeightDialog> createState() => _WeightDialogState();
}

class _WeightDialogState extends State<_WeightDialog> {
  late final _controller = TextEditingController(
    text: formatWeight(widget.current).replaceAll('×', ''),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final weight = parseWeight(_controller.text);
    if (weight == null) {
      setState(
        () => _error = 'Bobot harus lebih dari 0, contoh 1 atau 1,2 atau 0,5.',
      );
      return;
    }
    Navigator.of(context).pop(weight);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Bobot ${widget.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('weight-input'),
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Bobot (×)',
              helperText: '1 = normal, 1,2 = tamu, 0,5 = anak',
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            InlineError(_error!),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          key: const Key('weight-save'),
          onPressed: _submit,
          child: const Text('Simpan'),
        ),
      ],
    );
  }
}

class _GuestDialog extends StatefulWidget {
  const _GuestDialog();

  @override
  State<_GuestDialog> createState() => _GuestDialogState();
}

class _GuestDialogState extends State<_GuestDialog> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Nama tamu harus diisi.');
      return;
    }
    final phone = _phone.text.trim();
    Navigator.of(
      context,
    ).pop((name: name, phone: phone.isEmpty ? null : phone));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tambah tamu'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('guest-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nama tamu'),
          ),
          TextField(
            key: const Key('guest-phone'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Nomor WhatsApp (opsional)',
              helperText: 'Biar tagihannya bisa dikirim langsung',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            InlineError(_error!),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(
          key: const Key('guest-save'),
          onPressed: _submit,
          child: const Text('Tambah dan hadirkan'),
        ),
      ],
    );
  }
}
