import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petepete/api/api_client.dart';
import 'package:petepete/app/app_scope.dart';
import 'package:petepete/app/router.dart';
import 'package:petepete/auth/auth_controller.dart';
import 'package:petepete/auth/token_store.dart';
import 'package:petepete/features/groups/group_routes.dart';
import 'package:petepete/features/groups/uri_launcher.dart';
import 'package:petepete/ui/theme.dart';

import 'sample.dart';

/// One request the fake saw.
class Seen {
  Seen(this.method, this.path, this.body);

  final String method;
  final String path;
  final Map<String, dynamic> body;

  String get route => '$method $path';
}

/// An in-memory stand-in for the group, event, claim, payout and account endpoints,
/// behind a `MockClient` so the real [ApiClient], [GroupsApi] and screens run.
///
/// Every body is a recorded contract sample (ADR-0004) with this fake's state
/// patched in; the fake keeps only the behavior (who is host, claims, ids, errors).
class FakeGroupsApi {
  FakeGroupsApi() {
    client = MockClient(_handle);
  }

  static const baseUrl = 'http://api.test';

  late final http.Client client;

  /// `{id, name, template, role}` of the caller's groups.
  final groups = <Map<String, dynamic>>[];

  /// Roster per group id: `{id, display_name, role, has_account, pending_claim?}`.
  final members = <int, List<Map<String, dynamic>>>{};

  /// `GET /home` body per group id; build one with [emptyHome] / [sessionHome].
  final homes = <int, Sample>{};

  /// The group's payout account, or null for "none yet".
  Map<String, dynamic>? payout;

  /// Status the next payout registration answers.
  String registeredStatus = 'pending_kyc';

  /// Set to make `DELETE /api/me` answer 422 with this code.
  String? deleteAccountError;

  /// Set to make `POST /api/members/:id/claim` answer 409 with this code.
  String? claimError;

  /// Set to make `POST /api/invites/:token/join` answer 404.
  bool inviteExpired = false;

  /// What the invite link of group `id` is.
  String inviteUrl(int id) => 'https://petepete.test/join/token-$id';

  final seen = <Seen>[];

  /// `Idempotency-Key` header of every payout registration, in order.
  final payoutKeys = <String?>[];

  /// Set to make the next payout registration answer 502 `gateway_error` once.
  bool registerFailsOnce = false;
  int _nextId = 100;

  List<Seen> calls(String route) => [
    for (final s in seen)
      if (s.route == route) s,
  ];

  /// `you.member_id`: the first roster entry with the caller's role, else 1.
  int _viewerId(int groupId, String role) =>
      (members[groupId] ?? const []).firstWhere(
            (m) => m['role'] == role,
            orElse: () => {'id': 1},
          )['id']
          as int;

  Map<String, dynamic> _group(int id) =>
      groups.firstWhere((g) => g['id'] == id);

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(request.body) as Map<String, dynamic>;
    seen.add(Seen(request.method, path, body));
    final route = '${request.method} $path';

    RegExpMatch? m(String pattern) => RegExp('^$pattern\$').firstMatch(route);

    if (route == 'POST /api/auth/otp') return _sample('auth_otp.ok');
    if (route == 'POST /api/auth/verify') {
      return _sample('auth_verify.ok', {
        'access_token': 'access-1',
        'refresh_token': 'refresh-1',
        'new_user': false,
        'user': {'id': 1, 'display_name': 'Budi'},
      });
    }
    if (route == 'POST /api/auth/logout') return _sample('auth_logout.ok');
    if (route == 'GET /api/me') {
      return _sample('me.show', {
        'id': 1,
        'display_name': 'Budi',
        'phone': '6281200000000',
      });
    }
    if (route == 'DELETE /api/me') {
      final error = deleteAccountError;
      return error == null ? _sample('me.deleted') : _error(422, error);
    }
    if (route == 'GET /api/groups') {
      return _json(
        Sample.load('group_list.groups').withItems('groups', [
          for (final g in groups)
            {
              'id': g['id'],
              'name': g['name'],
              'template': g['template'],
              'role': g['role'],
              'role_label': roleLabel(g['role'] as String),
            },
        ]).body!,
      );
    }
    if (route == 'POST /api/groups') {
      final id = ++_nextId;
      groups.add({
        'id': id,
        'name': body['name'],
        'template': body['template'],
        'role': 'host',
      });
      final memberId = ++_nextId;
      members[id] = [
        {
          'id': memberId,
          'display_name': 'Budi',
          'role': 'host',
          'has_account': true,
        },
      ];
      homes[id] = emptyHome(id, body['name'] as String);
      return _sample('group_created.ok', {
        'group_id': id,
        'member_id': memberId,
        'name': body['name'],
        'template': body['template'],
        'invite_url': inviteUrl(id),
      }, 201);
    }
    if (m(r'GET /api/groups/(\d+)') case final match?) {
      final id = int.parse(match[1]!);
      final g = _group(id);
      final role = g['role'] as String;
      final host = role == 'host';
      final roster = members[id] ?? const <Map<String, dynamic>>[];
      return _json(
        Sample.load(host ? 'group_detail.host' : 'group_detail.member')
            .patch({
              'id': id,
              'name': g['name'],
              'template': g['template'],
              'invite_url': host ? inviteUrl(id) : null,
              'you': {
                'member_id': _viewerId(id, role),
                'role': role,
                'role_label': roleLabel(role),
              },
            })
            .withItems('members', [
              for (final member in roster)
                {
                  'id': member['id'],
                  'display_name': member['display_name'],
                  'role': member['role'],
                  'role_label': roleLabel(member['role'] as String),
                  'has_account': member['has_account'],
                  if (host) 'pending_claim': member['pending_claim'],
                },
            ])
            .body!,
      );
    }
    if (m(r'GET /api/groups/(\d+)/home') case final match?) {
      final home = homes[int.parse(match[1]!)];
      // The real API never sends `server_error`; a crash is a bare 500 page.
      return home == null
          ? http.Response('Internal Server Error', 500)
          : _json(home.body!);
    }
    if (m(r'POST /api/groups/(\d+)/invite/reset') case final match?) {
      return _sample('invite_reset.ok', {
        'invite_url': '${inviteUrl(int.parse(match[1]!))}-new',
      });
    }
    if (m(r'POST /api/groups/(\d+)/guests') case final match?) {
      final name = (body['name'] as String? ?? '').trim();
      if (name.isEmpty) return _error(422, 'invalid');
      final id = int.parse(match[1]!);
      members[id]!.add({
        'id': ++_nextId,
        'display_name': name,
        'role': 'guest',
        'has_account': false,
      });
      return _sample('guest.created', {'member_id': _nextId}, 201);
    }
    if (m(r'POST /api/groups/(\d+)/events') != null) {
      final recurring = body['type'] == 'recurring';
      return _sample(
        recurring ? 'event.recurring' : 'event.one_off',
        const {},
        201,
      );
    }
    if (m(r'GET /api/groups/(\d+)/payout-account/balance') != null) {
      final account = payout;
      if (account == null) return _error(422, 'no_payout_account');
      final status = account['status'] as String;
      return _sample('payout_balance.active', {
        'status': status,
        'status_label': payoutLabel(status),
        'bank_name': account['bank_name'],
        'account_last4': account['account_last4'],
        'balance': 0,
        'can_withdraw': status == 'active',
        'owner': true,
      });
    }
    if (m(r'POST /api/groups/(\d+)/payout-account') != null) {
      final key = request.headers['idempotency-key'];
      payoutKeys.add(key);
      if (key == null) return _error(422, 'idempotency_key_required');
      if (registerFailsOnce) {
        registerFailsOnce = false;
        return _error(502, 'gateway_error');
      }
      final number = body['account_number'] as String;
      payout = {
        'status': registeredStatus,
        'bank_name': body['bank_name'],
        'account_last4': number.substring(number.length - 4),
      };
      return _sample('payout_account.pending_kyc', {
        'status': registeredStatus,
        'status_label': payoutLabel(registeredStatus),
      }, 201);
    }
    if (m(r'POST /api/invites/([^/]+)/join') case final match?) {
      if (inviteExpired) return _error(404, 'not_found');
      final token = match[1]!;
      final id = int.parse(token.split('-').last);
      return _sample('invite_join.account', {
        'member_id': 1,
        'group': {'id': id, 'name': _group(id)['name']},
      }, 201);
    }
    if (m(r'POST /api/members/(\d+)/claim') != null) {
      final error = claimError;
      return error == null ? _sample('member_claim.ok') : _error(409, error);
    }
    if (m(r'POST /api/members/(\d+)/claim/(approve|reject)')
        case final match?) {
      final memberId = int.parse(match[1]!);
      for (final roster in members.values) {
        for (final member in roster) {
          if (member['id'] == memberId) {
            member.remove('pending_claim');
            if (match[2] == 'approve') member['has_account'] = true;
          }
        }
      }
      return _sample(
        match[2] == 'approve'
            ? 'member_claim.approved'
            : 'member_claim.rejected',
      );
    }
    return _error(404, 'not_found');
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  /// The recorded sample [name] with [overrides] applied (type-checked).
  http.Response _sample(
    String name, [
    Map<String, dynamic> overrides = const {},
    int status = 200,
  ]) => _json(Sample.load(name).patch(overrides).body!, status);

  /// The recorded error body for [code], with the server's own `message`.
  http.Response _error(int status, String code) =>
      _json(Sample.error(code).body!, status);
}

/// The server's label for a roster [role], read from a recorded roster.
String roleLabel(String role) {
  final roster = Sample.load('group_detail.member').json['members'] as List;
  return [
    for (final m in roster)
      if ((m as Map)['role'] == role) m['role_label'] as String,
  ].first;
}

/// The server's label for a payout account [status], read from the recorded
/// responses that carry one.
String payoutLabel(String status) => [
  for (final name in ['payout_account.pending_kyc', 'payout_balance.active'])
    if (Sample.load(name).json['status'] == status)
      Sample.load(name).json['status_label'] as String,
].first;

/// A home with nothing in it yet (`group_home.quiet`).
Sample emptyHome(int id, String name, {String role = 'host'}) =>
    Sample.load('group_home.quiet').patch({
      'group': {'id': id, 'name': name},
      'role': role,
      'role_label': roleLabel(role),
    });

/// A home recorded with a next session and one unpaid and one needs-review bill
/// (`group_home.with_session`); tests trim or override from here.
Sample sessionHome(int id, String name, {String role = 'host'}) =>
    Sample.load('group_home.with_session').patch({
      'group': {'id': id, 'name': name},
      'role': role,
      'role_label': roleLabel(role),
    });

/// The real client and controller wired to [fake], signed in as "Budi" unless
/// [signedIn] is false.
class AppHarness {
  AppHarness(this.fake, {bool signedIn = true}) {
    final tokens = MemoryTokenStore(
      signedIn
          ? const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1')
          : null,
    );
    api = ApiClient(
      baseUrl: FakeGroupsApi.baseUrl,
      httpClient: fake.client,
      tokens: tokens,
    );
    auth = AuthController(api: api, tokens: tokens);
  }

  final FakeGroupsApi fake;
  late final ApiClient api;
  late final AuthController auth;

  /// Every URI the app tried to open in another app, in order.
  final launched = <Uri>[];

  /// Whether the fake "phone" can open links (WhatsApp installed).
  bool canLaunch = true;

  /// The app's real router, with the real auth redirect.
  late final GoRouter appRouter = createRouter(auth);

  /// A router with only the group screens, for tests of one screen. The session and
  /// kas screens belong to other features; here they are stubs that show their path.
  GoRouter screenRouter(String initialLocation) => GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (context, state) => const Text('stub /')),
      ...groupRoutes,
      GoRoute(
        path: '/groups/:groupId/sessions/:sessionId',
        builder: (context, state) =>
            Scaffold(appBar: AppBar(), body: Text('stub ${state.uri.path}')),
      ),
      GoRoute(
        path: '/groups/:groupId/kas',
        builder: (context, state) =>
            Scaffold(appBar: AppBar(), body: Text('stub ${state.uri.path}')),
      ),
    ],
  );

  /// Pumps the app around [router] and waits for it to settle.
  Future<void> pump(
    WidgetTester tester,
    GoRouter router, {
    bool restore = true,
  }) async {
    if (restore) await auth.restore();
    // Tall enough that a whole screen is built, not just the part in view.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      LauncherScope(
        launch: (uri) async {
          launched.add(uri);
          return canLaunch;
        },
        child: AppScope(
          api: api,
          auth: auth,
          child: MaterialApp.router(
            theme: buildAppTheme(),
            routerConfig: router,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}
