import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/auth/auth_controller.dart';
import 'package:petepete/auth/token_store.dart';

import '../support/fake_api.dart';

const _phone = '6281234567890';

void main() {
  // The API sends every id as a JSON integer (`user: %{id: user.id, ...}` in
  // AuthController.verify, `render_user` in MeController); the fake does the same.
  group('the account id is the integer the API sends', () {
    test('parses the verify and /api/me payloads', () {
      final verify = AuthUser.fromJson({'id': 42, 'display_name': 'Budi'});
      final me = AuthUser.fromJson({
        'id': 42,
        'phone': _phone,
        'display_name': 'Budi',
      });
      expect(verify.id, 42);
      expect(me.id, 42);
      expect(me.displayName, 'Budi');
    });

    test('login through the verify call keeps the numeric id', () async {
      final fake = FakeApi();
      final app = buildApp(fake);

      await app.auth.requestOtp(_phone);
      await app.auth.verifyOtp('123456');

      expect(app.auth.user!.id, fake.accounts[_phone]!['id']);
      expect(app.auth.user!.id, isA<int>());
      expect(app.auth.status, AuthStatus.needsName);
    });

    test(
      'restoring a stored session reads the numeric id of /api/me',
      () async {
        final fake = FakeApi();
        final tokens = fake.signIn(_phone, displayName: 'Sari');
        final app = buildApp(fake, tokens: MemoryTokenStore(tokens));

        await app.auth.restore();

        expect(app.auth.status, AuthStatus.signedIn);
        expect(app.auth.user!.id, fake.accounts[_phone]!['id']);
        expect(app.auth.user!.displayName, 'Sari');
      },
    );
  });
}
