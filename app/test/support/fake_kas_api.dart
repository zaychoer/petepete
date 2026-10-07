import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petepete/api/api_client.dart';
import 'package:petepete/app/app_scope.dart';
import 'package:petepete/auth/auth_controller.dart';
import 'package:petepete/auth/token_store.dart';
import 'package:petepete/features/kas/kas_routes.dart';
import 'package:petepete/ui/external_link.dart';
import 'package:petepete/ui/rupiah.dart';
import 'package:petepete/ui/theme.dart';

import 'sample.dart';
import 'wire_labels.dart';

/// An in-memory stand-in for the ledger, group, balance and withdrawal endpoints, run
/// behind a `MockClient` so the real [ApiClient], [KasApi] and screens are exercised.
///
/// Every body is a recorded contract sample (`contract/samples`, ADR-0004) with the
/// ledger state patched in; the fake keeps only the behaviour (balances, txns,
/// idempotency, refusals).
///
/// Money POSTs honour `Idempotency-Key` like the real API: the same key returns the
/// first txn (`replayed: true`) and posts nothing new.
class FakeKasApi {
  FakeKasApi({this.host = true}) {
    client = MockClient(_handle);
  }

  late final http.Client client;

  /// Whether the signed-in member (id 1, "Budi") is the host.
  bool host;

  /// Roster: id -> name. Budi (1) is the signed-in member.
  final members = <int, String>{1: 'Budi', 2: 'Andi', 3: 'Citra'};

  /// Member balances and the kas (rupiah).
  final balances = <int, int>{1: 0, 2: 0, 3: 0};
  int kas = 0;

  /// History, oldest first; each map has the API's txn fields.
  final txns = <Map<String, dynamic>>[];

  /// Every request as `METHOD path?query`.
  final log = <String>[];

  /// Decoded bodies of money POSTs, in order, with their `Idempotency-Key`.
  final posts = <({String path, Map<String, dynamic> body, String? key})>[];

  /// Fail the next money POST like a dropped connection (the server still posts it
  /// when [dropAfterPosting] is true, as when only the response is lost).
  int failNextPosts = 0;

  /// Answer the next money POST with the recorded error sample of `code` (and post
  /// nothing).
  ({int status, String code})? failNextWith;
  bool dropAfterPosting = false;

  /// Withdrawal and sub-account state.
  int subBalance = 250000;
  bool payoutOwner = true;
  String payoutStatus = 'active';
  bool hasPayoutAccount = true;
  String? managedUrl;
  final withdrawals = <Map<String, dynamic>>[];

  final _byKey = <String, Map<String, dynamic>>{};
  int _nextTxn = 1;
  int _nextWithdrawal = 1;
  DateTime _clock = DateTime.utc(2026, 10, 6, 10);

  int get ledgerTxnCount => txns.length;

  /// Adds a history row as the server lists it: the recorded withdrawal with these
  /// values and the recorded `status_label` of [status].
  void addWithdrawal({
    required int id,
    required int amount,
    required String status,
    String? providerRef,
    String? managedUrl,
    DateTime? insertedAt,
  }) {
    final rows =
        Sample.load('withdrawals.history').withItems('withdrawals', [
              {
                'id': id,
                'amount': amount,
                'status': status,
                'status_label': WireLabels.withdrawal(status),
                'provider_ref': providerRef,
                'managed_url': managedUrl,
                'inserted_at': (insertedAt ?? DateTime.utc(2026, 10, 6, 12))
                    .toIso8601String(),
              },
            ]).json['withdrawals']
            as List;
    withdrawals.add(rows.single as Map<String, dynamic>);
  }

  /// Seeds a txn as if it already happened. [kindLabel] overrides the recorded
  /// `kind_label` of [kind] (needed for a kind no sample records).
  int seed(
    String kind,
    String description,
    List<(int?, int)> entries, {
    String? reason,
    int? reverses,
    String? kindLabel,
  }) {
    final id = _nextTxn++;
    _clock = _clock.add(const Duration(minutes: 5));
    txns.add({
      'id': id,
      'kind': kind,
      'kind_label': kindLabel ?? WireLabels.txnKind(kind),
      'description': description,
      'reason': reason,
      'reverses_txn_id': reverses,
      'actor_type': 'host',
      'inserted_at': _clock.toIso8601String(),
      'entries': [
        for (final (memberId, amount) in entries)
          {
            'account_type': memberId == null ? 'kas' : 'member',
            'member_id': memberId,
            'display_name': memberId == null ? null : members[memberId],
            'amount': amount,
          },
      ],
    });
    for (final (memberId, amount) in entries) {
      if (memberId == null) {
        kas += amount;
      } else {
        balances[memberId] = balances[memberId]! + amount;
      }
    }
    return id;
  }

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    log.add(
      '${request.method} $path'
      '${request.url.query.isEmpty ? '' : '?${request.url.query}'}',
    );
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    final key = request.headers['idempotency-key'];

    if (request.method == 'POST') {
      posts.add((path: path, body: body, key: key));
      final refusal = failNextWith;
      if (refusal != null) {
        failNextWith = null;
        return _error(refusal.status, refusal.code);
      }
      if (failNextPosts > 0) {
        failNextPosts--;
        if (dropAfterPosting) _post(path, body, key);
        throw http.ClientException('offline');
      }
      return _post(path, body, key);
    }

    switch (path) {
      case '/api/groups/1':
        final myRole = host ? 'host' : 'member';
        return _json(
          Sample.load('group_detail.host')
              .patch({
                'id': 1,
                'you': {
                  'member_id': 1,
                  'role': myRole,
                  'role_label': WireLabels.role(myRole),
                },
              })
              .withItems('members', [
                for (final e in members.entries)
                  {
                    'id': e.key,
                    'display_name': e.value,
                    'role': e.key == 1 ? myRole : 'member',
                    'role_label': WireLabels.role(
                      e.key == 1 ? myRole : 'member',
                    ),
                  },
              ])
              .json,
        );
      case '/api/groups/1/balances':
        return _json(
          Sample.load('balances.members').patch({'kas': kas}).withItems(
            'members',
            [
              for (final e in members.entries)
                {
                  'member_id': e.key,
                  'display_name': e.value,
                  'balance': balances[e.key],
                },
            ],
          ).json,
        );
      case '/api/groups/1/txns':
        final filter = int.tryParse(
          request.url.queryParameters['member_id'] ?? '',
        );
        final shown = txns.where((t) {
          if (filter == null) return true;
          return (t['entries'] as List).any((e) => e['member_id'] == filter);
        });
        return _json(
          Sample.load(
            'txns.history',
          ).withItems('txns', shown.toList().reversed.toList()).json,
        );
      case '/api/groups/1/payout-account/balance':
        if (!hasPayoutAccount) return _error(422, 'no_payout_account');
        return _json(
          Sample.load('payout_balance.active').patch({
            'balance': subBalance,
            'payout_account_id': 7,
            'status': payoutStatus,
            'status_label': WireLabels.payoutAccount(payoutStatus),
            'bank_name': 'BCA',
            'account_last4': '4321',
            'owner': payoutOwner,
            'can_withdraw': payoutOwner && payoutStatus == 'active',
          }).json,
        );
      case '/api/groups/1/withdrawals':
        return _json(
          Sample.load(
            'withdrawals.history',
          ).withItems('withdrawals', withdrawals.reversed.toList()).json,
        );
    }
    return _error(404, 'not_found');
  }

  http.Response _post(String path, Map<String, dynamic> body, String? key) {
    if (key == null) return _error(422, 'idempotency_key_required');
    final first = _byKey[key];
    if (first != null) return _json({...first, 'replayed': true});

    final result = switch (path) {
      '/api/groups/1/settlements' => _settlement(body),
      '/api/groups/1/kas-spends' => _kasSpend(body),
      '/api/groups/1/withdrawals' => _withdraw(body),
      _ when RegExp(r'^/api/txns/\d+/correction$').hasMatch(path) =>
        _correction(int.parse(path.split('/')[3]), body),
      _ => _error(404, 'not_found'),
    };
    if (result.statusCode == 201) {
      _byKey[key] = jsonDecode(result.body) as Map<String, dynamic>
        ..remove('replayed');
    }
    return result;
  }

  http.Response _recorded(String sample, int txnId) => _json(
    Sample.load(sample).patch({'txn_id': txnId, 'replayed': false}).json,
    201,
  );

  http.Response _settlement(Map<String, dynamic> body) {
    final payer = body['from_member_id'] as int;
    final payee = body['to_member_id'] as int;
    final amount = body['amount'] as int;
    if (amount <= 0) return _error(422, 'amount_not_positive');
    if (payer == payee) return _error(422, 'same_member');
    final id = seed(
      'settlement',
      '${members[payer]} bayar ${formatRupiah(amount)} ke ${members[payee]}',
      [(payer, amount), (payee, -amount)],
      reason: body['note'] as String?,
    );
    return _recorded('settlement.recorded', id);
  }

  http.Response _kasSpend(Map<String, dynamic> body) {
    final who = body['member_id'] as int;
    final amount = body['amount'] as int;
    if (amount <= 0) return _error(422, 'amount_not_positive');
    if (amount > kas) return _error(422, 'insufficient_kas');
    final note = body['note'] as String?;
    final id = seed(
      'kas_spend',
      '${members[who]} beli ${note ?? ''} ${formatRupiah(amount)} pakai kas',
      [(null, -amount), (who, amount)],
      reason: note,
    );
    return _recorded('kas_spend.recorded', id);
  }

  http.Response _correction(int txnId, Map<String, dynamic> body) {
    final original = txns.where((t) => t['id'] == txnId).firstOrNull;
    // The API answers an unknown txn with its own `txn_not_found`; no sample
    // records it, so the closest recorded error stands in.
    if (original == null) return _error(404, 'not_found');
    final reason = (body['reason'] as String?)?.trim() ?? '';
    if (reason.isEmpty) return _error(422, 'reason_required');
    if (original['kind'] != 'settlement' && original['kind'] != 'kas_spend') {
      return _error(422, 'not_undoable');
    }
    if (txns.any((t) => t['reverses_txn_id'] == txnId)) {
      return _error(422, 'already_reversed');
    }
    final id = seed(
      'correction',
      'Dikoreksi: ${original['description']}. Alasan: $reason',
      [
        for (final e in original['entries'] as List)
          (e['member_id'] as int?, -(e['amount'] as int)),
      ],
      reason: reason,
      reverses: txnId,
    );
    return _recorded('correction.recorded', id);
  }

  http.Response _withdraw(Map<String, dynamic> body) {
    final amount = body['amount'] as int;
    if (!payoutOwner) return _error(403, 'forbidden');
    if (amount <= 0) return _error(422, 'amount_not_positive');
    if (amount > subBalance) return _error(422, 'insufficient_balance');
    final id = _nextWithdrawal++;
    final managed = managedUrl != null;
    final status = managed ? 'managed' : 'submitted';
    if (!managed) subBalance -= amount;
    addWithdrawal(
      id: id,
      amount: amount,
      status: status,
      managedUrl: managedUrl,
    );
    return _json(
      Sample.load(
        managed ? 'withdrawal.managed' : 'withdrawal.submitted',
      ).patch({
        'withdrawal_id': id,
        'managed_url': managedUrl,
        'replayed': false,
      }).json,
      201,
    );
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response _error(int status, String code) =>
      _json(Sample.error(code).json, status);
}

/// Pumps the Kas routes (plus a stub payout-registration route) at [location], signed
/// in against [fake]. [launched] collects URLs the injected launcher was asked to open;
/// the launcher answers [launcherResult].
Future<void> pumpKas(
  WidgetTester tester,
  FakeKasApi fake, {
  String location = '/groups/1/kas',
  List<Uri>? launched,
  bool launcherResult = true,
}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tokens = MemoryTokenStore(
    const AuthTokens(accessToken: 'a', refreshToken: 'r'),
  );
  final api = ApiClient(
    baseUrl: 'http://api.test',
    httpClient: fake.client,
    tokens: tokens,
  );
  final auth = AuthController(api: api, tokens: tokens);
  Future<bool> launcher(Uri url) async {
    launched?.add(url);
    return launcherResult;
  }

  final UrlLauncher launchUrl = launcher;
  final router = GoRouter(
    initialLocation: location,
    routes: [
      ...kasRoutes(launchUrl: launchUrl),
      GoRoute(
        path: '/groups/:groupId/payout-account/register',
        name: KasRoutes.payoutRegister,
        builder: (context, state) =>
            const Scaffold(body: Text('Daftar rekening pencairan')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    AppScope(
      api: api,
      auth: auth,
      child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
    ),
  );
  // Do NOT use pumpAndSettle here: the withdraw screen's CircularProgressIndicator
  // is an infinite animation that prevents settling. Pump enough frames for the
  // fake HTTP response to complete and the screen to rebuild.
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}
