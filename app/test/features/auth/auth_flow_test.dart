import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/app/app.dart';
import 'package:petepete/auth/token_store.dart';

import '../../support/fake_api.dart';

const _phone = '6281234567890';
// A user with no group lands on the onboarding screen.
const _homeText = 'Bikin grup pertamamu';

final _phoneField = find.widgetWithText(TextField, 'Nomor WhatsApp');
final _codeField = find.widgetWithText(TextField, 'Kode 6 digit');
final _nameField = find.widgetWithText(TextField, 'Nama tampilan');

Future<void> _launch(
  WidgetTester tester,
  FakeApi fake, {
  MemoryTokenStore? tokens,
}) async {
  final app = buildApp(fake, tokens: tokens);
  await tester.pumpWidget(PetepeteApp(api: app.api, auth: app.auth));
  await tester.pumpAndSettle();
}

Future<void> _enterPhone(WidgetTester tester, String text) async {
  await tester.enterText(_phoneField, text);
  await tester.pump();
}

Future<void> _requestCode(
  WidgetTester tester, [
  String text = '0812-3456-7890',
]) async {
  await _enterPhone(tester, text);
  await tester.tap(find.text('Kirim kode'));
  await tester.pump();
  await tester.pump();
}

Future<void> _enterCode(WidgetTester tester, String code) async {
  await tester.enterText(_codeField, code);
  await tester.pumpAndSettle();
}

void main() {
  group('login', () {
    testWidgets('new user: phone, code, name, then home', (tester) async {
      final fake = FakeApi();
      await _launch(tester, fake);
      expect(find.text('Masuk ke Petepete'), findsOneWidget);

      await _requestCode(tester);
      expect(fake.otpRequests, [_phone]); // normalised to 62… before sending
      expect(find.text('Masukkan kode'), findsOneWidget);

      await _enterCode(tester, '123456');
      expect(find.text('Siapa namamu?'), findsOneWidget);

      await tester.enterText(_nameField, '  Budi  ');
      await tester.pump();
      await tester.tap(find.text('Lanjut'));
      await tester.pumpAndSettle();

      expect(find.text(_homeText), findsOneWidget);
      expect(fake.accounts[_phone]!['display_name'], 'Budi');
    });

    testWidgets('existing user with a name skips the name step', (
      tester,
    ) async {
      final fake = FakeApi()
        ..accounts[_phone] = {'id': 90, 'display_name': 'Sari'};
      await _launch(tester, fake);

      await _requestCode(tester);
      await _enterCode(tester, '123456');

      expect(find.text('Siapa namamu?'), findsNothing);
      expect(find.text(_homeText), findsOneWidget);
    });

    testWidgets('an account that never set a name is asked again', (
      tester,
    ) async {
      final fake = FakeApi()..accounts[_phone] = {'id': 90, 'display_name': ''};
      await _launch(tester, fake);

      await _requestCode(tester);
      await _enterCode(tester, '123456');

      expect(find.text('Siapa namamu?'), findsOneWidget);
    });

    testWidgets(
      'shows how the typed number will be sent, and blocks a bad one',
      (tester) async {
        await _launch(tester, FakeApi());

        await _enterPhone(tester, '0812');
        expect(find.textContaining('belum lengkap'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
          isNull,
        );

        await _enterPhone(tester, '+62 812 3456 7890');
        expect(find.text('Kode dikirim ke +62 812-3456-7890'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('wrong code shows an Indonesian error and allows another try', (
      tester,
    ) async {
      final fake = FakeApi();
      await _launch(tester, fake);
      await _requestCode(tester);

      await _enterCode(tester, '000000');

      expect(
        find.textContaining('Kode salah atau sudah kedaluwarsa'),
        findsOneWidget,
      );
      expect(find.text('Masukkan kode'), findsOneWidget);

      await _enterCode(tester, '123456');
      expect(find.text('Siapa namamu?'), findsOneWidget);
    });

    testWidgets('rate limit on the first request stays on the phone screen', (
      tester,
    ) async {
      final fake = FakeApi()..otpRateLimited = true;
      await _launch(tester, fake);

      await _requestCode(tester);

      expect(find.textContaining('terlalu sering minta kode'), findsOneWidget);
      expect(find.text('Masuk ke Petepete'), findsOneWidget);
    });

    testWidgets(
      'resend waits out the cooldown, then shows the rate limit message',
      (tester) async {
        final fake = FakeApi();
        await _launch(tester, fake);
        await _requestCode(tester);
        expect(find.text('Kirim ulang kode (30 dtk)'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Kirim ulang kode (30 dtk)'),
              )
              .onPressed,
          isNull,
        );

        await tester.pump(const Duration(seconds: 30));
        await tester.pump();
        await tester.tap(find.text('Kirim ulang kode'));
        await tester.pump();
        expect(find.text('Kode baru sudah dikirim.'), findsOneWidget);
        expect(fake.otpRequests, [_phone, _phone]);

        fake.otpRateLimited = true;
        await tester.pump(const Duration(seconds: 30));
        await tester.pump();
        await tester.tap(find.text('Kirim ulang kode'));
        await tester.pump();
        await tester.pump();

        expect(
          find.textContaining('terlalu sering minta kode'),
          findsOneWidget,
        );
        expect(find.text('Kode baru sudah dikirim.'), findsNothing);
      },
    );
  });

  group('name', () {
    testWidgets('the Lanjut button stays off until a name is typed', (
      tester,
    ) async {
      final fake = FakeApi();
      await _launch(tester, fake);
      await _requestCode(tester);
      await _enterCode(tester, '123456');

      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
        isNull,
      );
      await tester.enterText(_nameField, '   ');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
        isNull,
      );
    });
  });

  group('session', () {
    testWidgets('a stored session restores straight to home', (tester) async {
      final fake = FakeApi();
      final tokens = MemoryTokenStore(fake.signIn(_phone, displayName: 'Budi'));

      await _launch(tester, fake, tokens: tokens);

      expect(find.text(_homeText), findsOneWidget);
      expect(find.text('Masuk ke Petepete'), findsNothing);
    });

    testWidgets('logging in survives an app restart', (tester) async {
      final fake = FakeApi();
      final store = MemoryTokenStore();
      await _launch(tester, fake, tokens: store);
      await _requestCode(tester);
      await _enterCode(tester, '123456');
      await tester.enterText(_nameField, 'Budi');
      await tester.pump();
      await tester.tap(find.text('Lanjut'));
      await tester.pumpAndSettle();
      expect(find.text(_homeText), findsOneWidget);

      // "Close" the app: tear down the widget tree, keep only the stored tokens.
      await tester.pumpWidget(const SizedBox());
      await _launch(tester, fake, tokens: store);

      expect(find.text(_homeText), findsOneWidget);
    });

    testWidgets('an expired access token is refreshed once on restore', (
      tester,
    ) async {
      final fake = FakeApi();
      final tokens = MemoryTokenStore(fake.signIn(_phone));
      fake.expireAccessTokens();

      await _launch(tester, fake, tokens: tokens);

      expect(find.text(_homeText), findsOneWidget);
      expect(fake.refreshCalls, 1);
    });

    testWidgets('a revoked session lands on login and forgets the tokens', (
      tester,
    ) async {
      final fake = FakeApi();
      final tokens = MemoryTokenStore(fake.signIn(_phone));
      fake.expireAccessTokens();
      fake.revokeRefreshTokens();

      await _launch(tester, fake, tokens: tokens);

      expect(find.text('Masuk ke Petepete'), findsOneWidget);
      expect(await tokens.read(), isNull);
    });

    testWidgets('offline at start keeps the session and offers a retry', (
      tester,
    ) async {
      final fake = FakeApi();
      final tokens = MemoryTokenStore(fake.signIn(_phone));
      fake.offline = true;
      await _launch(tester, fake, tokens: tokens);

      expect(find.textContaining('Tidak bisa terhubung'), findsOneWidget);
      expect(await tokens.read(), isNotNull);

      fake.offline = false;
      await tester.tap(find.text('Coba lagi'));
      await tester.pumpAndSettle();

      expect(find.text(_homeText), findsOneWidget);
    });

    testWidgets('Keluar ends the session and returns to login', (tester) async {
      final fake = FakeApi();
      final tokens = MemoryTokenStore(fake.signIn(_phone));
      await _launch(tester, fake, tokens: tokens);

      await tester.tap(find.byTooltip('Akun'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keluar'));
      await tester.pumpAndSettle();

      expect(find.text('Masuk ke Petepete'), findsOneWidget);
      expect(await tokens.read(), isNull);
      expect(fake.log, contains('POST /api/auth/logout'));
    });
  });
}
