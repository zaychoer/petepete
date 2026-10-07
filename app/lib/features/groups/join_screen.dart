import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import 'async_body.dart';
import 'group_paths.dart';
import 'groups_api.dart';

/// Opened by an invite link (`https://<web host>/join/<token>`), from the app when
/// installed. Two ways in:
///
/// * a plain link joins as a new member under the account's name;
/// * `?claim=<member id>` (the roster entry the person already got on the web join
///   page) asks to take that entry over instead, so their history stays theirs. The
///   host has to approve, and no ledger row moves.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key, required this.token, this.claimMemberId});

  final String token;
  final int? claimMemberId;

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> {
  TextEditingController? _name;
  bool _busy = false;
  bool _claimSent = false;
  String? _error;

  TextEditingController get _nameController => _name ??= TextEditingController(
    text: AppScope.of(context).auth.user?.displayName ?? '',
  );

  @override
  void dispose() {
    _name?.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(GroupsApi api) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(GroupsApi(AppScope.of(context).api));
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() => _run((api) async {
    final result = await api.join(
      widget.token,
      displayName: _nameController.text.trim(),
    );
    if (mounted) context.go(GroupRoutes.groupHomePath(result.groupId));
  });

  Future<void> _claim() => _run((api) async {
    await api.claim(widget.claimMemberId!);
    if (mounted) setState(() => _claimSent = true);
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final claiming = widget.claimMemberId != null;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 48),
              if (_claimSent) ...[
                Text('Permintaan terkirim', style: textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  'Host perlu menyetujui dulu. Setelah disetujui, namamu di grup '
                  'tertaut ke akun ini dan riwayatmu tetap utuh.',
                  style: textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => context.go('/'),
                  child: const Text('Selesai'),
                ),
              ] else if (claiming) ...[
                Text('Klaim namamu', style: textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  'Kamu sudah masuk daftar grup ini lewat link. Ajukan supaya '
                  'namamu tertaut ke akun ini. Host akan menyetujuinya.',
                  style: textTheme.bodyLarge,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  InlineError(_error!),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _claim,
                  child: BusyButtonChild(
                    busy: _busy,
                    label: 'Ini aku, ajukan klaim',
                  ),
                ),
              ] else ...[
                Text('Gabung ke grup', style: textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(
                  'Pakai nama yang dikenal teman-temanmu di grup ini.',
                  style: textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _nameController,
                  maxLength: 60,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Namamu di grup',
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  InlineError(_error!),
                ],
                const SizedBox(height: 24),
                ListenableBuilder(
                  listenable: _nameController,
                  builder: (context, _) => FilledButton(
                    onPressed: _busy || _nameController.text.trim().isEmpty
                        ? null
                        : _join,
                    child: BusyButtonChild(busy: _busy, label: 'Gabung'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
