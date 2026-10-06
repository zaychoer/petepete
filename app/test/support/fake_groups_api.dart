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
/// Mirrors the real contract (statuses, `{"error": code}` bodies, int ids).
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

  /// `GET /home` body per group id.
  final homes = <int, Map<String, dynamic>>{};

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

    if (route == 'POST /api/auth/otp') return _json({'ok': true});
    if (route == 'POST /api/auth/verify') {
      return _json({
        'access_token': 'access-1',
        'refresh_token': 'refresh-1',
        'token_type': 'Bearer',
        'expires_in': 900,
        'new_user': false,
        'user': {'id': 1, 'display_name': 'Budi'},
      });
    }
    if (route == 'POST /api/auth/logout') return _json({'ok': true});
    if (route == 'GET /api/me') {
      return _json({'id': 1, 'display_name': 'Budi', 'phone': '6281200000000'});
    }
    if (route == 'DELETE /api/me') {
      final error = deleteAccountError;
      return error == null ? _json({'ok': true}) : _error(422, error);
    }
    if (route == 'GET /api/groups') return _json({'groups': groups});
    if (route == 'POST /api/groups') {
      final id = ++_nextId;
      groups.add({
        'id': id,
        'name': body['name'],
        'template': body['template'],
        'role': 'host',
      });
      members[id] = [
        {
          'id': ++_nextId,
          'display_name': 'Budi',
          'role': 'host',
          'has_account': true,
        },
      ];
      homes[id] = emptyHome(id, body['name'] as String);
      return _json({'group_id': id, 'invite_url': inviteUrl(id)}, 201);
    }
    if (m(r'GET /api/groups/(\d+)') case final match?) {
      final id = int.parse(match[1]!);
      final g = _group(id);
      final host = g['role'] == 'host';
      return _json({
        'id': id,
        'name': g['name'],
        'template': g['template'],
        'rounding_unit': 1000,
        'cost_categories': ['Sewa lapangan', 'Air minum'],
        'invite_url': host ? inviteUrl(id) : null,
        'members': members[id] ?? [],
        'you': {
          'member_id': _viewerId(id, g['role'] as String),
          'role': g['role'],
        },
      });
    }
    if (m(r'GET /api/groups/(\d+)/home') case final match?) {
      final home = homes[int.parse(match[1]!)];
      return home == null ? _error(500, 'server_error') : _json(home);
    }
    if (m(r'POST /api/groups/(\d+)/invite/reset') case final match?) {
      return _json({'invite_url': '${inviteUrl(int.parse(match[1]!))}-new'});
    }
    if (m(r'POST /api/groups/(\d+)/guests') case final match?) {
      final name = (body['name'] as String? ?? '').trim();
      if (name.isEmpty) return _invalid({'name': "can't be blank"});
      final id = int.parse(match[1]!);
      members[id]!.add({
        'id': ++_nextId,
        'display_name': name,
        'role': 'guest',
        'has_account': false,
      });
      return _json({'member_id': _nextId}, 201);
    }
    if (m(r'POST /api/groups/(\d+)/events') != null) {
      return _json({'event_id': 1, 'session_id': null}, 201);
    }
    if (m(r'GET /api/groups/(\d+)/payout-account/balance') != null) {
      final account = payout;
      return account == null
          ? _error(422, 'no_payout_account')
          : _json({...account, 'balance': 0, 'owner': true});
    }
    if (m(r'POST /api/groups/(\d+)/payout-account') != null) {
      payout = {
        'status': registeredStatus,
        'bank_name': body['bank_name'],
        'account_last4': (body['account_number'] as String).substring(
          (body['account_number'] as String).length - 4,
        ),
      };
      return _json({'payout_account_id': 1, 'status': registeredStatus}, 201);
    }
    if (m(r'POST /api/invites/([^/]+)/join') case final match?) {
      if (inviteExpired) return _error(404, 'not_found');
      final token = match[1]!;
      final id = int.parse(token.split('-').last);
      return _json({
        'member_id': 1,
        'group': {'id': id, 'name': _group(id)['name']},
        'claim': {'claimable': false},
      }, 201);
    }
    if (m(r'POST /api/members/(\d+)/claim') != null) {
      final error = claimError;
      return error == null ? _json({'ok': true}) : _error(409, error);
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
      return _json({'ok': true});
    }
    return _error(404, 'not_found');
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response _error(int status, String code) =>
      _json({'error': code}, status);

  http.Response _invalid(Map<String, String> errors) =>
      _json({'error': 'invalid', 'errors': errors, 'fields': errors}, 422);
}

/// A home with nothing in it yet.
Map<String, dynamic> emptyHome(int id, String name, {String role = 'host'}) => {
  'group': {'id': id, 'name': name},
  'role': role,
  'next_session': null,
  'kas_balance': 0,
  'unpaid_bills': <Object>[],
  'needs_review_bills': <Object>[],
};

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
