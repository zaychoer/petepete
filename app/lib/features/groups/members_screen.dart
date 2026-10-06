import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../auth/phone.dart';
import '../../ui/inline_error.dart';
import 'async_body.dart';
import 'groups_api.dart';
import 'invite.dart';

/// The roster: members and guests, the invite button, resetting the link, adding a
/// guest, and (host only) the pending claims to approve or reject.
class MembersScreen extends StatelessWidget {
  const MembersScreen({super.key, required this.groupId});

  final int groupId;

  @override
  Widget build(BuildContext context) {
    final api = GroupsApi(AppScope.of(context).api);
    return Scaffold(
      appBar: AppBar(title: const Text('Anggota')),
      body: AsyncBody<GroupDetail>(
        load: () => api.group(groupId),
        builder: (context, group, reload) =>
            _Roster(api: api, group: group, reload: reload),
      ),
    );
  }
}

class _Roster extends StatefulWidget {
  const _Roster({required this.api, required this.group, required this.reload});

  final GroupsApi api;
  final GroupDetail group;
  final Future<void> Function() reload;

  @override
  State<_Roster> createState() => _RosterState();
}

class _RosterState extends State<_Roster> {
  String? _error;

  GroupDetail get group => widget.group;

  Future<void> _decide(RosterMember member, {required bool approve}) async {
    setState(() => _error = null);
    try {
      await (approve
          ? widget.api.approveClaim(member.id)
          : widget.api.rejectClaim(member.id));
      await widget.reload();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = groupErrorMessage(e));
    }
  }

  Future<void> _addGuest() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => AddGuestDialog(api: widget.api, groupId: group.id),
    );
    if (added == true) await widget.reload();
  }

  Future<void> _resetInvite() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset link undangan?'),
        content: const Text(
          'Link yang lama langsung tidak bisa dipakai lagi. '
          'Yang sudah jadi anggota tetap aman.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Ya, reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.resetInvite(group.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Link baru sudah dibuat. Tekan Undang untuk membagikannya.',
          ),
        ),
      );
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = groupErrorMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final claims = group.members
        .where((m) => m.pendingClaimName != null)
        .toList();
    return RefreshIndicator(
      onRefresh: widget.reload,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(group.name, style: textTheme.headlineSmall),
          if (group.isHost) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Undang'),
              onPressed: () => inviteViaWhatsApp(context, widget.api, group.id),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _addGuest,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Tambah tamu'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _resetInvite,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Reset link'),
                  ),
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            InlineError(_error!),
          ],
          if (claims.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('Permintaan klaim nama', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final m in claims)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${m.pendingClaimName} ingin memakai nama "${m.name}"',
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Riwayat tagihan dan kas "${m.name}" ikut ke akunnya kalau kamu setujui.',
                        style: textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => _decide(m, approve: false),
                            child: Text('Tolak ${m.name}'),
                          ),
                          FilledButton(
                            onPressed: () => _decide(m, approve: true),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            child: Text('Setujui ${m.name}'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: 20),
          Text(
            'Daftar anggota (${group.members.length})',
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          for (final m in group.members)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline),
              title: Text(m.name),
              subtitle: Text(
                [
                  _roleLabel(m),
                  if (!m.hasAccount && !m.isGuest) 'belum punya akun',
                ].join(' · '),
              ),
            ),
        ],
      ),
    );
  }
}

String _roleLabel(RosterMember m) => switch (m.role) {
  'host' => 'Host',
  'guest' => 'Tamu',
  _ => 'Anggota',
};

/// Name (required) and WhatsApp number (optional) of a guest to add to the roster.
class AddGuestDialog extends StatefulWidget {
  const AddGuestDialog({super.key, required this.api, required this.groupId});

  final GroupsApi api;
  final int groupId;

  @override
  State<AddGuestDialog> createState() => _AddGuestDialogState();
}

class _AddGuestDialogState extends State<AddGuestDialog> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _phoneError;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Nama tamu harus diisi.');
      return;
    }
    if (phone.isNotEmpty && normalizePhone(phone) == null) {
      setState(() {
        _error = null;
        _phoneError = 'Nomor tidak valid. Contoh: 0812-3456-7890.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _phoneError = null;
    });
    try {
      await widget.api.addGuest(
        widget.groupId,
        name: name,
        phone: phone.isEmpty ? null : normalizePhone(phone),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = groupErrorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tambah tamu'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              maxLength: 60,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nama tamu'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Nomor WhatsApp (opsional)',
                helperText: 'Kosongkan kalau tidak perlu.',
                errorText: _phoneError,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              InlineError(_error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
          child: BusyButtonChild(busy: _busy, label: 'Tambah'),
        ),
      ],
    );
  }
}
