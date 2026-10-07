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
import 'package:petepete/features/session/link_launcher.dart';
import 'package:petepete/features/session/session_routes.dart';
import 'package:petepete/ui/theme.dart';

/// A stand-in for the session endpoints (group roster, session detail, costs,
/// attendance, preview, issue, share, cash, void) behind a `MockClient`, so the
/// real [ApiClient] and the session screens run against the real wire format.
///
/// Money is not computed here: [previewJson] is what the server would answer.
/// The fake only keeps the state the screens edit (costs, attendance, status) and
/// derives `bearer_ids` like the server does.
class FakeSessionServer {
  FakeSessionServer() {
    client = MockClient(_handle);
  }

  late final http.Client client;

  static const hostId = 1;

  /// The caller's role in the group (`you.role`). As a `member` the fake answers
  /// every host-only route with 403 `forbidden`, like the real API.
  String youRole = 'host';

  /// The caller's member id (`you.member_id`).
  int youMemberId = hostId;

  /// Roster as the group endpoint returns it.
  final members = <Map<String, dynamic>>[
    {'id': 1, 'display_name': 'Budi', 'role': 'host'},
    {'id': 2, 'display_name': 'Sari', 'role': 'member'},
    {'id': 3, 'display_name': 'Andi', 'role': 'member'},
  ];

  final categories = ['Lapangan', 'Shuttlecock', 'Minum'];

  String status = 'draft';
  String progress = 'draft';

  /// member id -> {attended, weight}
  final participants = <int, Map<String, dynamic>>{};
  final costs = <Map<String, dynamic>>[];
  int _costSeq = 100;
  int _memberSeq = 50;

  /// Answer for GET preview once the session is billable; null = compute nothing.
  Map<String, dynamic>? previewJson;

  /// Bills of the issued session, as share/bills returns them.
  List<Map<String, dynamic>> shareBills = [];
  Map<String, dynamic>? reminderJson;
  Map<String, dynamic>? summaryJson;

  /// Set to make the next call of that route answer an error:
  /// key `METHOD /path`, value `(status, body)`.
  final failures = <String, (int, Map<String, dynamic>)>{};

  final log = <String>[];
  final bodies = <String, List<Map<String, dynamic>>>{};
  final keys = <String, List<String?>>{};

  Iterable<int> bearersOf(Map<String, dynamic> cost) {
    final attending = [
      for (final e in participants.entries)
        if (e.value['attended'] == true) e.key,
    ];
    if (cost['scope'] == 'subset') {
      final selected = (cost['members'] as List).cast<int>();
      return attending.where(selected.contains);
    }
    return attending;
  }

  Map<String, dynamic> _costOut(Map<String, dynamic> c) => {
    ...c,
    'paid_by_name': members.firstWhere(
      (m) => m['id'] == c['paid_by'],
    )['display_name'],
    'members': c['members'] ?? <int>[],
    'bearer_ids': bearersOf(c).toList(),
  };

  Map<String, dynamic> _participantOut(int id) => {
    'member_id': id,
    'display_name': members.firstWhere((m) => m['id'] == id)['display_name'],
    'role': members.firstWhere((m) => m['id'] == id)['role'],
    ...participants[id]!,
  };

  /// Routes only the host may call; they answer a member 403.
  static final _hostOnly = RegExp(
    r'^(PUT|DELETE) /api/sessions/\d+/(costs|attendance)'
    r'|^POST /api/groups/\d+/guests$'
    r'|^GET /api/sessions/\d+/(preview|share/bills|share/reminder)$'
    r'|^POST /api/sessions/\d+/(issue|void)$'
    r'|^POST /api/bills/',
  );

  Future<http.Response> _handle(http.Request r) async {
    final route = '${r.method} ${r.url.path}';
    log.add(route);
    keys.putIfAbsent(route, () => []).add(r.headers['idempotency-key']);
    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    if (r.body.isNotEmpty) bodies.putIfAbsent(route, () => []).add(body);

    final failure = failures.remove(route);
    if (failure != null) return _json(failure.$2, failure.$1);
    if (youRole != 'host' && _hostOnly.hasMatch(route)) {
      return _json({'error': 'forbidden'}, 403);
    }

    switch (route) {
      case 'GET /api/groups/1':
        return _json({
          'id': 1,
          'members': members,
          'cost_categories': categories,
          'you': {'member_id': youMemberId, 'role': youRole},
        });
      case 'POST /api/groups/1/guests':
        final id = ++_memberSeq;
        members.add({'id': id, 'display_name': body['name'], 'role': 'guest'});
        return _json({'member_id': id}, 201);
      case 'GET /api/sessions/10':
        return _json({
          'session': {
            'id': 10,
            'group_id': 1,
            'starts_at': '2026-10-06T11:00:00Z',
            'status': status,
            'progress': progress,
          },
          'cost_items': [for (final c in costs) _costOut(c)],
          'participants': [
            for (final id in participants.keys) _participantOut(id),
          ],
        });
      case 'PUT /api/sessions/10/attendance':
        final id = body['member_id'] as int;
        final current = participants[id] ?? {'attended': false, 'weight': 1000};
        final weight = body['weight'];
        if (weight is! int || weight <= 0) {
          if (body.containsKey('weight')) {
            return _json({
              'error': 'invalid',
              'errors': {
                'weight': ['must be greater than 0'],
              },
            }, 422);
          }
        }
        participants[id] = {
          'attended': body['attended'] ?? current['attended'],
          'weight': body['weight'] ?? current['weight'],
        };
        return _json({'participant': _participantOut(id)});
      case 'GET /api/sessions/10/preview':
        final problems = [
          for (final c in costs)
            if (bearersOf(c).isEmpty)
              {'code': 'item_without_bearers', 'id': c['id']},
        ];
        if (problems.isNotEmpty) {
          return _json({'error': 'invalid_session', 'problems': problems}, 422);
        }
        return _json(previewJson!);
      case 'POST /api/sessions/10/issue':
        status = 'issued';
        progress = 'issued';
        return _json({
          'session_id': 10,
          'txn_id': 7,
          'replayed': false,
          'bills': [],
        });
      case 'GET /api/sessions/10/share/bills':
        return _json({'session_id': 10, 'bills': shareBills});
      case 'GET /api/sessions/10/share/reminder':
        return _json(reminderJson!);
      case 'GET /api/sessions/10/share/summary':
        return _json(summaryJson!);
      case 'POST /api/sessions/10/void':
        status = 'draft';
        progress = 'draft';
        return _json({'txn_id': 8, 'replayed': false, 'session_id': 10}, 201);
    }

    final put = RegExp(r'^PUT /api/sessions/10/costs/(\w+)$').firstMatch(route);
    if (put != null) {
      final id = put.group(1) == 'new' ? ++_costSeq : int.parse(put.group(1)!);
      final item = {'id': id, 'session_id': 10, ...body};
      costs.removeWhere((c) => c['id'] == id);
      costs.add(item);
      return _json({
        'cost_item': _costOut(item),
      }, put.group(1) == 'new' ? 201 : 200);
    }
    final del = RegExp(
      r'^DELETE /api/sessions/10/costs/(\d+)$',
    ).firstMatch(route);
    if (del != null) {
      costs.removeWhere((c) => c['id'] == int.parse(del.group(1)!));
      return http.Response('', 204);
    }
    final cash = RegExp(
      r'^POST /api/bills/(\d+)/cash(/cancel)?$',
    ).firstMatch(route);
    if (cash != null) {
      final bill = shareBills.firstWhere(
        (b) => b['bill_id'] == int.parse(cash.group(1)!),
      );
      final paying = cash.group(2) == null;
      bill['status'] = paying ? 'paid' : 'unpaid';
      bill['paid_via'] = paying ? 'cash' : null;
      bill['paid_at'] = paying ? '2026-10-06T12:00:00Z' : null;
      bill['cash_cancellable'] = paying;
      return _json({
        'txn_id': 9,
        'replayed': false,
        'bill': {'id': bill['bill_id'], 'status': bill['status']},
      });
    }
    return _json({'error': 'not_found'}, 404);
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}

/// Records what the app asked the OS to open.
class FakeLauncher implements LinkLauncher {
  final opened = <Uri>[];
  bool succeeds = true;

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return succeeds;
  }
}

/// Shows the session route at `/groups/1/sessions/10` with the real client wired to
/// [server].
Future<void> pumpSession(
  WidgetTester tester,
  FakeSessionServer server,
  FakeLauncher launcher,
) async {
  final tokens = MemoryTokenStore(
    const AuthTokens(accessToken: 'a', refreshToken: 'r'),
  );
  final api = ApiClient(
    baseUrl: 'http://api.test',
    httpClient: server.client,
    tokens: tokens,
  );
  final auth = AuthController(api: api, tokens: tokens);
  final router = GoRouter(
    initialLocation: '/groups/1/sessions/10',
    routes: [sessionRoute(launcher: launcher)],
  );
  addTearDown(router.dispose);
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    AppScope(
      api: api,
      auth: auth,
      child: MaterialApp.router(theme: buildAppTheme(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}
