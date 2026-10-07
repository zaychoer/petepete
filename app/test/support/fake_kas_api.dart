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

/// An in-memory stand-in for the ledger, group, balance and withdrawal endpoints, run
/// behind a `MockClient` so the real [ApiClient], [KasApi] and screens are exercised.
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

  /// Answer the next money POST with this error (and post nothing).
  ({int status, String code, String? message})? failNextWith;
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

  /// Seeds a txn as if it already happened.
  int seed(
    String kind,
    String description,
    List<(int?, int)> entries, {
    String? reason,
    int? reverses,
  }) {
    final id = _nextTxn++;
    _clock = _clock.add(const Duration(minutes: 5));
    txns.add({
      'id': id,
      'kind': kind,
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
        return _error(refusal.status, refusal.code, refusal.message);
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
        return _json({
          'id': 1,
          'name': 'Futsal Kamis',
          'members': [
            for (final e in members.entries)
              {
                'id': e.key,
                'display_name': e.value,
                'role': e.key == 1 && host ? 'host' : 'member',
              },
          ],
          'you': {'member_id': 1, 'role': host ? 'host' : 'member'},
        });
      case '/api/groups/1/balances':
        return _json({
          'kas': kas,
          'members': [
            for (final e in members.entries)
              {
                'member_id': e.key,
                'display_name': e.value,
                'balance': balances[e.key],
              },
          ],
        });
      case '/api/groups/1/txns':
        final filter = int.tryParse(
          request.url.queryParameters['member_id'] ?? '',
        );
        final shown = txns.where((t) {
          if (filter == null) return true;
          return (t['entries'] as List).any((e) => e['member_id'] == filter);
        });
        return _json({'txns': shown.toList().reversed.toList()});
      case '/api/groups/1/payout-account/balance':
        if (!hasPayoutAccount) {
          return _error(
            422,
            'no_payout_account',
            'Grup belum punya rekening pencairan.',
          );
        }
        return _json({
          'balance': subBalance,
          'payout_account_id': 7,
          'status': payoutStatus,
          'bank_name': 'BCA',
          'account_last4': '4321',
          'owner': payoutOwner,
          'can_withdraw': payoutOwner && payoutStatus == 'active',
        });
      case '/api/groups/1/withdrawals':
        return _json({'withdrawals': withdrawals.reversed.toList()});
    }
    return _error(404, 'not_found');
  }

  http.Response _post(String path, Map<String, dynamic> body, String? key) {
    if (key == null) {
      return _error(
        422,
        'idempotency_key_required',
        'Header Idempotency-Key wajib diisi.',
      );
    }
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

  http.Response _settlement(Map<String, dynamic> body) {
    final payer = body['from_member_id'] as int;
    final payee = body['to_member_id'] as int;
    final amount = body['amount'] as int;
    if (amount <= 0) {
      return _error(
        422,
        'amount_not_positive',
        'Nominal harus lebih dari Rp0.',
      );
    }
    if (payer == payee) {
      return _error(
        422,
        'same_member',
        'Pembayar dan penerima tidak boleh orang yang sama.',
      );
    }
    final id = seed(
      'settlement',
      '${members[payer]} bayar ${formatRupiah(amount)} ke ${members[payee]}',
      [(payer, amount), (payee, -amount)],
      reason: body['note'] as String?,
    );
    return _json({'txn_id': id, 'replayed': false}, 201);
  }

  http.Response _kasSpend(Map<String, dynamic> body) {
    final who = body['member_id'] as int;
    final amount = body['amount'] as int;
    if (amount <= 0) {
      return _error(
        422,
        'amount_not_positive',
        'Nominal harus lebih dari Rp0.',
      );
    }
    if (amount > kas) {
      return _error(
        422,
        'insufficient_kas',
        'Saldo kas tidak cukup untuk belanja ini.',
      );
    }
    final note = body['note'] as String?;
    final id = seed(
      'kas_spend',
      '${members[who]} beli ${note ?? ''} ${formatRupiah(amount)} pakai kas',
      [(null, -amount), (who, amount)],
      reason: note,
    );
    return _json({'txn_id': id, 'replayed': false}, 201);
  }

  http.Response _correction(int txnId, Map<String, dynamic> body) {
    final original = txns.where((t) => t['id'] == txnId).firstOrNull;
    if (original == null) {
      return _error(422, 'txn_not_found', 'Catatan tidak ditemukan.');
    }
    final reason = (body['reason'] as String?)?.trim() ?? '';
    if (reason.isEmpty) {
      return _error(422, 'reason_required', 'Alasan wajib diisi.');
    }
    if (original['kind'] != 'settlement' && original['kind'] != 'kas_spend') {
      return _error(422, 'not_undoable', 'Catatan ini tidak bisa dikoreksi.');
    }
    if (txns.any((t) => t['reverses_txn_id'] == txnId)) {
      return _error(
        422,
        'already_reversed',
        'Catatan ini sudah pernah dikoreksi.',
      );
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
    return _json({'txn_id': id, 'replayed': false}, 201);
  }

  http.Response _withdraw(Map<String, dynamic> body) {
    final amount = body['amount'] as int;
    if (!payoutOwner) return _error(403, 'forbidden');
    if (amount <= 0) {
      return _error(
        422,
        'amount_not_positive',
        'Nominal harus lebih dari Rp0.',
      );
    }
    if (amount > subBalance) {
      return _error(
        422,
        'insufficient_balance',
        'Saldo sub-account tidak cukup untuk penarikan ini.',
      );
    }
    final id = _nextWithdrawal++;
    final managed = managedUrl != null;
    final status = managed ? 'managed' : 'submitted';
    final label = managed
        ? 'Selesaikan di dashboard gateway'
        : 'Penarikan diajukan';
    if (!managed) subBalance -= amount;
    withdrawals.add({
      'id': id,
      'amount': amount,
      'status': status,
      'status_label': label,
      'provider_ref': null,
      'managed_url': managedUrl,
      'inserted_at': DateTime.utc(2026, 10, 6, 12).toIso8601String(),
    });
    return _json({
      'withdrawal_id': id,
      'status': status,
      'status_label': label,
      'managed_url': managedUrl,
      'replayed': false,
    }, 201);
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response _error(int status, String code, [String? message]) =>
      _json({'error': code, 'message': ?message}, status);
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
  await tester.pumpAndSettle();
}
