import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../ui/external_link.dart';
import 'kas_screen.dart';
import 'kas_spend_screen.dart';
import 'settlement_screen.dart';
import 'withdraw_screen.dart';

/// Route names of Kas & riwayat, corrections, settlements, kas spends and Tarik dana.
/// Push with `context.pushNamed(KasRoutes.kas, pathParameters: {'groupId': '1'})`.
abstract final class KasRoutes {
  static const kas = 'kas';
  static const settlement = 'kasSettlement';
  static const spend = 'kasSpend';
  static const withdraw = 'withdraw';

  /// Owned by the groups screens (PP-PAY-01 app slice); Tarik dana links to it when
  /// the group has no payout account yet.
  static const payoutRegister = 'payoutRegister';
}

/// Append to the router's routes: `...kasRoutes()`. Tests pass their own [launchUrl].
List<GoRoute> kasRoutes({UrlLauncher launchUrl = openExternally}) => [
  GoRoute(
    path: '/groups/:groupId/kas',
    name: KasRoutes.kas,
    builder: (context, state) =>
        _withGroupId(state, (id) => KasScreen(groupId: id)),
  ),
  GoRoute(
    path: '/groups/:groupId/kas/settlement',
    name: KasRoutes.settlement,
    builder: (context, state) =>
        _withGroupId(state, (id) => SettlementScreen(groupId: id)),
  ),
  GoRoute(
    path: '/groups/:groupId/kas/spend',
    name: KasRoutes.spend,
    builder: (context, state) =>
        _withGroupId(state, (id) => KasSpendScreen(groupId: id)),
  ),
  GoRoute(
    path: '/groups/:groupId/withdraw',
    name: KasRoutes.withdraw,
    builder: (context, state) => _withGroupId(
      state,
      (id) => WithdrawScreen(groupId: id, launchUrl: launchUrl),
    ),
  ),
];

Widget _withGroupId(GoRouterState state, Widget Function(int groupId) build) {
  final id = int.tryParse(state.pathParameters['groupId'] ?? '');
  if (id == null) {
    return const Scaffold(body: Center(child: Text('Grup tidak ditemukan.')));
  }
  return build(id);
}
