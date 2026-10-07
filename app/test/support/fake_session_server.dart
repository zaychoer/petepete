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

import 'sample.dart';
import 'wire_labels.dart';

/// One entry of `share/bills` as the server sends it: the recorded entry with these
/// values and the recorded labels of [status] and [paidVia] (a paid bill defaults
/// to cash paid at noon, cancellable). A `void` entry has no text, link or pay URL.
Map<String, dynamic> shareBill(
  int id,
  String name,
  String status,
  int due, {
  String? paidVia,
  String? paidAt,
  bool? cashCancellable,
  String? waNumber,
  String? text,
  String? shareUrl,
}) {
  final paid = status == 'paid';
  final via = paidVia ?? (paid ? 'cash' : null);
  final live = status != 'void';
  final entry =
      (Sample.load('share_bills.issued').withItems('bills', [
                {
                  'bill_id': id,
                  'member_id': id + 10,
                  'display_name': name,
                  'status': status,
                  'status_label': WireLabels.bill(status),
                  'amount_due': due,
                  'paid_via': via,
                  'paid_via_label': via == null
                      ? null
                      : WireLabels.paidVia(via),
                  'paid_at': paidAt ?? (paid ? '2026-10-06T12:00:00Z' : null),
                  'cash_cancellable':
                      cashCancellable ?? (paid && via == 'cash'),
                  'has_phone': waNumber != null,
                  'wa_number': waNumber,
                  'pay_url': live && !paid ? 'https://pay.test/p/$id' : null,
                  'text': live ? (text ?? 'Halo $name') : null,
                  'share_url': live
                      ? (shareUrl ?? 'https://wa.me/?text=Halo')
                      : null,
                },
              ]).json['bills']
              as List)
          .single;
  return entry as Map<String, dynamic>;
}

/// One line of a preview member, recorded shape.
Map<String, dynamic> previewLine(int costItemId, String label, int amount) =>
    ((Sample.load('preview.ok').patch({
                      'members.0.lines.0': {
                        'cost_item_id': costItemId,
                        'category': label,
                        'label': label,
                        'amount': amount,
                        'fraction': {'numerator': amount, 'denominator': 1},
                      },
                    }).json['members']
                    as List)
                .first['lines']
            as List)
        .first
        .cast<String, dynamic>();

/// A preview body: the recorded preview with [totals] patched in and one
/// element per [items] / [members] entry, built from the recorded first element.
Map<String, dynamic> previewBody({
  Map<String, dynamic> totals = const {},
  List<Map<String, dynamic>> items = const [],
  List<Map<String, dynamic>> members = const [],
}) => Sample.load(
  'preview.ok',
).patch(totals).withItems('items', items).withItems('members', members).json;

/// The `share/reminder` body: the recorded reminder with [bills] (from
/// [shareBill]) and [overrides] patched in.
Map<String, dynamic> reminderBody(
  List<Map<String, dynamic>> bills, [
  Map<String, dynamic> overrides = const {},
]) => Sample.load(
  'share_reminder.owing',
).patch({'count': bills.length, ...overrides}).withItems('bills', bills).json;

/// The `share/summary` body: the recorded summary with [overrides] patched in.
Map<String, dynamic> summaryBody(Map<String, dynamic> overrides) =>
    Sample.load('share_summary.issued').patch(overrides).json;

/// A stand-in for the session endpoints (group roster, session detail, costs,
/// attendance, preview, issue, share, cash, void) behind a `MockClient`, so the
/// real [ApiClient] and the session screens run against the real wire format.
///
/// Every body is a recorded contract sample (`contract/samples`, ADR-0004) with the
/// state patched in. Money is not computed here: [previewJson] is what the server
/// would answer. The fake only keeps the state the screens edit (costs, attendance,
/// status) and derives `bearer_ids` like the server does.
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

  /// Roster as the group endpoint returns it (`id`, `display_name`, `role`).
  final members = <Map<String, dynamic>>[
    {'id': 1, 'display_name': 'Budi', 'role': 'host'},
    {'id': 2, 'display_name': 'Sari', 'role': 'member'},
    {'id': 3, 'display_name': 'Andi', 'role': 'member'},
  ];

  final categories = ['Lapangan', 'Shuttlecock', 'Minum'];

  /// Stored session status (`draft | issued | cancelled`) and derived progress
  /// (`draft | issued | settled | cancelled`).
  String status = 'draft';
  String progress = 'draft';

  /// member id -> {attended, weight}
  final participants = <int, Map<String, dynamic>>{};
  final costs = <Map<String, dynamic>>[];
  int _costSeq = 100;
  int _memberSeq = 50;

  /// Answer for GET preview once the session is billable (see [previewBody]).
  Map<String, dynamic>? previewJson;

  /// Bills of the issued session, as share/bills returns them (see [shareBill]).
  List<Map<String, dynamic>> shareBills = [];
  Map<String, dynamic>? reminderJson;
  Map<String, dynamic>? summaryJson;

  /// Set to make the next call of that route answer an error:
  /// key `METHOD /path`, value `(status, body)`. Use [fail].
  final failures = <String, (int, Map<String, dynamic>)>{};

  /// The next call of [route] (`METHOD /path`) answers the recorded error sample
  /// of [code] with [status].
  void fail(String route, int status, String code) =>
      failures[route] = (status, Sample.error(code).json);

  /// Code of the problems `GET preview` lists for an item nobody bears
  /// (`invalid_session` problems).
  String problemCode = 'item_without_bearers';

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

  Map<String, dynamic> _member(int id) =>
      members.firstWhere((m) => m['id'] == id);

  Map<String, dynamic> _costOut(Map<String, dynamic> c) => {
    'id': c['id'],
    'session_id': c['session_id'],
    'category': c['category'],
    'label': c['label'],
    'amount': c['amount'],
    'paid_by': c['paid_by'],
    'paid_by_name': _member(c['paid_by'] as int)['display_name'],
    'scope': c['scope'],
    'members': c['members'] ?? <int>[],
    'bearer_ids': bearersOf(c).toList(),
  };

  Map<String, dynamic> _participantOut(int id) {
    final role = _member(id)['role'] as String;
    return {
      'member_id': id,
      'display_name': _member(id)['display_name'],
      'role': role,
      'role_label': WireLabels.role(role),
      'attended': participants[id]!['attended'],
      'weight': participants[id]!['weight'],
    };
  }

  /// The recorded session sample that matches the current [status]/[progress].
  Sample _sessionSample() => Sample.load(switch (progress) {
    'settled' => 'session.settled',
    'cancelled' => 'session.cancelled',
    _ when status == 'issued' => 'session.issued',
    _ => 'session.draft',
  });

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
    if (failure != null) {
      final (code, payload) = failure;
      return _json(payload, code);
    }
    if (youRole != 'host' && _hostOnly.hasMatch(route)) {
      return _error(403, 'forbidden');
    }

    switch (route) {
      case 'GET /api/groups/1':
        return _json(
          Sample.load('group_detail.host')
              .patch({
                'id': 1,
                'cost_categories': categories,
                'you': {
                  'member_id': youMemberId,
                  'role': youRole,
                  'role_label': WireLabels.role(youRole),
                },
              })
              .withItems('members', [
                for (final m in members)
                  {
                    'id': m['id'],
                    'display_name': m['display_name'],
                    'role': m['role'],
                    'role_label': WireLabels.role(m['role'] as String),
                  },
              ])
              .json,
        );
      case 'POST /api/groups/1/guests':
        final id = ++_memberSeq;
        members.add({'id': id, 'display_name': body['name'], 'role': 'guest'});
        return _json(
          Sample.load('guest.created').patch({'member_id': id}).json,
          201,
        );
      case 'GET /api/sessions/10':
        return _json(
          _sessionSample()
              .patch({
                'session': {
                  'id': 10,
                  'event_id': 10,
                  'group_id': 1,
                  'starts_at': '2026-10-06T11:00:00Z',
                  'status': status,
                  'status_label': WireLabels.session(status),
                  'progress': progress,
                  'progress_label': WireLabels.session(progress),
                },
              })
              .withItems('cost_items', [for (final c in costs) _costOut(c)])
              .withItems('participants', [
                for (final id in participants.keys) _participantOut(id),
              ])
              .json,
        );
      case 'PUT /api/sessions/10/attendance':
        final id = body['member_id'] as int;
        final current = participants[id] ?? {'attended': false, 'weight': 1000};
        final weight = body['weight'];
        if (weight is! int || weight <= 0) {
          if (body.containsKey('weight')) {
            // The recorded `invalid` sample names one field (`name`); the key
            // stands for the field here, the app only reads the message.
            const text = ['harus lebih dari 0'];
            return _json(
              Sample.error('invalid').patch({
                'errors': {'name': text},
                'fields': {'name': text},
              }).json,
              422,
            );
          }
        }
        participants[id] = {
          'attended': body['attended'] ?? current['attended'],
          'weight': body['weight'] ?? current['weight'],
        };
        return _json(
          Sample.load(
            'participant.saved',
          ).patch({'participant': _participantOut(id)}).json,
        );
      case 'GET /api/sessions/10/preview':
        final problems = [
          for (final c in costs)
            if (bearersOf(c).isEmpty) {'code': problemCode, 'id': c['id']},
        ];
        if (problems.isNotEmpty) {
          // The server's own `message` of each problem stays as recorded.
          return _json(
            Sample.error(
              'invalid_session',
            ).withItems('problems', problems).json,
            422,
          );
        }
        return _json(previewJson!);
      case 'POST /api/sessions/10/issue':
        status = 'issued';
        progress = 'issued';
        return _json(
          Sample.load('issue.issued')
              .patch({'session_id': 10, 'txn_id': 7, 'replayed': false})
              .withItems('bills', [
                for (final b in shareBills)
                  {
                    'id': b['bill_id'],
                    'member_id': b['member_id'],
                    'display_name': b['display_name'],
                    'amount_due': b['amount_due'],
                    'share': b['amount_due'],
                    'status': b['status'],
                    'status_label': b['status_label'],
                    'paid_via': b['paid_via'],
                    'paid_via_label': b['paid_via_label'],
                  },
              ])
              .json,
        );
      case 'GET /api/sessions/10/share/bills':
        return _json(
          Sample.load(
            'share_bills.issued',
          ).patch({'session_id': 10}).withItems('bills', shareBills).json,
        );
      case 'GET /api/sessions/10/share/reminder':
        return _json(reminderJson!);
      case 'GET /api/sessions/10/share/summary':
        return _json(summaryJson!);
      case 'POST /api/sessions/10/void':
        status = 'draft';
        progress = 'draft';
        return _json(
          Sample.load(
            'void.voided',
          ).patch({'session_id': 10, 'txn_id': 8, 'replayed': false}).json,
          201,
        );
    }

    final put = RegExp(r'^PUT /api/sessions/10/costs/(\w+)$').firstMatch(route);
    if (put != null) {
      final id = put.group(1) == 'new' ? ++_costSeq : int.parse(put.group(1)!);
      final item = {'id': id, 'session_id': 10, ...body};
      costs.removeWhere((c) => c['id'] == id);
      costs.add(item);
      return _json(
        Sample.load(
          'cost_item.saved',
        ).patch({'cost_item': _costOut(item)}).json,
        put.group(1) == 'new' ? 201 : 200,
      );
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
      final newStatus = paying ? 'paid' : 'unpaid';
      bill['status'] = newStatus;
      bill['status_label'] = WireLabels.bill(newStatus);
      bill['paid_via'] = paying ? 'cash' : null;
      bill['paid_via_label'] = paying ? WireLabels.paidVia('cash') : null;
      bill['paid_at'] = paying ? '2026-10-06T12:00:00Z' : null;
      bill['cash_cancellable'] = paying;
      return _json(
        Sample.load(paying ? 'bill_cash.paid' : 'bill_cash.cancelled').patch({
          'txn_id': 9,
          'replayed': false,
          'bill': {
            'id': bill['bill_id'],
            'amount_due': bill['amount_due'],
            'status': bill['status'],
            'status_label': bill['status_label'],
            'paid_via': bill['paid_via'],
            'paid_via_label': bill['paid_via_label'],
            'paid_at': bill['paid_at'],
          },
        }).json,
      );
    }
    return _error(404, 'not_found');
  }

  http.Response _error(int status, String code) =>
      _json(Sample.error(code).json, status);

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
