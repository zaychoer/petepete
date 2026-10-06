import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:petepete/api/api_client.dart';
import 'package:petepete/app/router.dart';
import 'package:petepete/auth/auth_controller.dart';
import 'package:petepete/auth/token_store.dart';
import 'package:petepete/features/groups/group_paths.dart';
import 'package:petepete/features/kas/kas_routes.dart';
import 'package:petepete/features/session/session_routes.dart';

import '../support/fake_kas_api.dart';

void main() {
  late GoRouter router;

  setUp(() {
    final tokens = MemoryTokenStore(
      const AuthTokens(accessToken: 'a', refreshToken: 'r'),
    );
    final api = ApiClient(
      baseUrl: 'http://api.test',
      httpClient: FakeKasApi().client,
      tokens: tokens,
    );
    router = createRouter(AuthController(api: api, tokens: tokens));
    addTearDown(router.dispose);
  });

  bool resolves(String location) =>
      !router.configuration.findMatch(Uri.parse(location)).isError;

  // The Kas screens link to the payout screens by name; the group screens and the Kas and
  // session screens come from different features, so check the merged table.
  test('the screens other features link to resolve in the app router', () {
    final links = {
      KasRoutes.kas: {'groupId': '1'},
      KasRoutes.withdraw: {'groupId': '1'},
      KasRoutes.payoutRegister: {'groupId': '1'},
      SessionRoutes.detail: {'groupId': '1', 'sessionId': '2'},
    };
    for (final MapEntry(key: name, value: params) in links.entries) {
      final location = router.namedLocation(name, pathParameters: params);
      expect(resolves(location), isTrue, reason: '$name -> $location');
    }
    expect(KasRoutes.payoutRegister, GroupRoutes.payoutRegister);
    expect(
      router.namedLocation(
        KasRoutes.payoutRegister,
        pathParameters: {'groupId': '1'},
      ),
      '/groups/1/payout-account/register',
    );
  });
}
