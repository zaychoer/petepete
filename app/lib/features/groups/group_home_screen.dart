import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_scope.dart';
import '../../ui/rupiah.dart';
import '../../ui/status_chip.dart';
import 'async_body.dart';
import 'group_paths.dart';
import 'groups_api.dart';
import 'invite.dart';
import 'wib.dart';

/// Beranda grup: the next session, the kas balance, who still has to pay and which
/// payments need a check. One request (`GET /api/groups/:id/home`).
class GroupHomeScreen extends StatelessWidget {
  const GroupHomeScreen({super.key, required this.groupId});

  final int groupId;

  @override
  Widget build(BuildContext context) {
    final api = GroupsApi(AppScope.of(context).api);
    return AsyncBody<GroupHome>(
      fullScreen: true,
      load: () => api.home(groupId),
      builder: (context, home, reload) => Scaffold(
        appBar: AppBar(
          title: const Text('Beranda'),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Menu',
              onSelected: (value) => _onMenu(context, value),
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'members', child: Text('Anggota')),
                if (home.isHost)
                  const PopupMenuItem(
                    value: 'payout',
                    child: Text('Rekening pencairan'),
                  ),
                const PopupMenuItem(value: 'groups', child: Text('Grup lain')),
                const PopupMenuItem(value: 'account', child: Text('Akun')),
              ],
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: reload,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                home.groupName,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (home.isHost) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('Undang'),
                        onPressed: () =>
                            inviteViaWhatsApp(context, api, groupId),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.event),
                        label: const Text('Buat event'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: () async {
                          await context.pushNamed(
                            GroupRoutes.newEvent,
                            pathParameters: {'groupId': '$groupId'},
                          );
                          await reload();
                        },
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              _NextSessionCard(groupId: groupId, home: home),
              const SizedBox(height: 12),
              _KasCard(groupId: groupId, balance: home.kasBalance),
              const SizedBox(height: 20),
              _BillSection(
                groupId: groupId,
                title: 'Belum bayar',
                emptyText: 'Tidak ada tagihan yang menunggu pembayaran.',
                bills: home.unpaid,
              ),
              const SizedBox(height: 20),
              _BillSection(
                groupId: groupId,
                title: 'Perlu dicek',
                emptyText: 'Tidak ada pembayaran yang perlu dicek.',
                bills: home.needsReview,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _onMenu(BuildContext context, String value) {
    switch (value) {
      case 'members':
        context.pushNamed(
          GroupRoutes.members,
          pathParameters: {'groupId': '$groupId'},
        );
      case 'payout':
        context.pushNamed(
          GroupRoutes.payoutRegister,
          pathParameters: {'groupId': '$groupId'},
        );
      case 'groups':
        context.goNamed(GroupRoutes.groups);
      case 'account':
        context.pushNamed(GroupRoutes.account);
    }
  }
}

class _NextSessionCard extends StatelessWidget {
  const _NextSessionCard({required this.groupId, required this.home});

  final int groupId;
  final GroupHome home;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final next = home.nextSession;
    if (next == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sesi berikutnya', style: textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                home.isHost
                    ? 'Belum ada sesi. Buat event dulu, nanti sesinya muncul di sini.'
                    : 'Belum ada sesi yang dijadwalkan.',
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push(GroupRoutes.sessionPath(groupId, next.id)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Sesi berikutnya',
                      style: textTheme.titleMedium,
                    ),
                  ),
                  StatusChip.session(
                    next.status,
                    settled: next.progress == 'settled',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(next.eventName, style: textTheme.titleLarge),
              Text(formatSessionTime(next.startsAt)),
              const SizedBox(height: 8),
              Text(
                '${next.attendedCount} hadir · total biaya ${formatRupiah(next.costTotal)}',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KasCard extends StatelessWidget {
  const _KasCard({required this.groupId, required this.balance});

  final int groupId;
  final int balance;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/groups/$groupId/kas'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Saldo kas', style: textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(formatRupiah(balance), style: textTheme.headlineSmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _BillSection extends StatelessWidget {
  const _BillSection({
    required this.groupId,
    required this.title,
    required this.emptyText,
    required this.bills,
  });

  final int groupId;
  final String title;
  final String emptyText;
  final List<OpenBill> bills;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          bills.isEmpty ? title : '$title (${bills.length})',
          style: textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (bills.isEmpty)
          Text(emptyText, style: textTheme.bodyMedium)
        else
          for (final bill in bills)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(bill.memberName),
                subtitle: Text(
                  '${bill.eventName} · ${formatSessionTime(bill.sessionStartsAt)}',
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatRupiah(bill.amountDue),
                      style: textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    StatusChip.bill(bill.status),
                  ],
                ),
                onTap: () => context.push(
                  GroupRoutes.sessionPath(groupId, bill.sessionId),
                ),
              ),
            ),
      ],
    );
  }
}
