import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import '../groups/async_body.dart';
import '../groups/group_paths.dart';
import '../groups/groups_api.dart';

/// The user's account: who they are, log out, and the way to delete the account.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AppScope.of(context).auth;
    return Scaffold(
      appBar: AppBar(title: const Text('Akun')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListenableBuilder(
            listenable: auth,
            builder: (context, _) => Text(
              auth.user?.displayName ?? '',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: auth.logout,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Keluar'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => context.pushNamed(GroupRoutes.deleteAccount),
            child: const Text('Hapus akun'),
          ),
        ],
      ),
    );
  }
}

/// Deleting the account (UU PDP). The server refuses while the user still hosts a
/// group; the screen shows that message instead of leaving.
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus akun?'),
        content: const Text(
          'Akunmu dihapus permanen dan tidak bisa dikembalikan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Ya, hapus akunku'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final scope = AppScope.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await GroupsApi(scope.api).deleteAccount();
      // The account is gone: forget the session; the router moves to login.
      await scope.auth.logout();
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Hapus akun')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Yang terjadi kalau akunmu dihapus',
            style: textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            '• Nama dan nomor HP-mu dihapus dari Petepete.\n'
            '• Catatan keuangan grup tetap ada supaya hitungan teman-temanmu tidak berubah, '
            'tapi namamu diganti jadi "Mantan anggota".\n'
            '• Kamu tidak bisa menghapus akun selama masih jadi host grup aktif.',
          ),
          const SizedBox(height: 24),
          if (_error != null) ...[
            InlineError(_error!),
            const SizedBox(height: 16),
          ],
          FilledButton(
            onPressed: _busy ? null : _confirmAndDelete,
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: BusyButtonChild(busy: _busy, label: 'Hapus akun saya'),
          ),
        ],
      ),
    );
  }
}
