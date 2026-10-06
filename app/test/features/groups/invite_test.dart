import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_groups_api.dart';
import '../../support/sample.dart';

FakeGroupsApi _hostOfFutsal() {
  final fake = FakeGroupsApi();
  fake.groups.add({
    'id': 5,
    'name': 'Futsal Kamis',
    'template': 'Futsal',
    'role': 'host',
  });
  fake.homes[5] = emptyHome(5, 'Futsal Kamis');
  fake.members[5] = [
    {'id': 1, 'display_name': 'Budi', 'role': 'host', 'has_account': true},
  ];
  return fake;
}

/// Delivers [url] the way Android hands over a link the user tapped while the app
/// is running.
Future<void> _openLink(WidgetTester tester, String url) async {
  final message = const JSONMethodCodec().encodeMethodCall(
    MethodCall('pushRouteInformation', {'location': url}),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    message,
    (_) {},
  );
  await tester.pumpAndSettle();
}

void main() {
  group('Undang', () {
    testWidgets(
      'opens WhatsApp through wa.me with the text and the invite link',
      (tester) async {
        final fake = _hostOfFutsal();
        final app = AppHarness(fake);
        await app.pump(tester, app.screenRouter('/groups/5'));

        await tester.tap(find.text('Undang'));
        await tester.pumpAndSettle();

        final uri = app.launched.single;
        expect(uri.scheme, 'https');
        expect(uri.host, 'wa.me');
        expect(
          uri.path,
          '/',
          reason: 'no phone number: the host picks the chat',
        );
        final text = uri.queryParameters['text']!;
        expect(text, contains('Futsal Kamis'));
        expect(text, contains(fake.inviteUrl(5)));
      },
    );

    testWidgets('offers the link to copy when WhatsApp cannot be opened', (
      tester,
    ) async {
      final fake = _hostOfFutsal();
      final app = AppHarness(fake)..canLaunch = false;
      await app.pump(tester, app.screenRouter('/groups/5'));

      await tester.tap(find.text('Undang'));
      await tester.pumpAndSettle();

      expect(find.text('WhatsApp tidak bisa dibuka'), findsOneWidget);
      expect(find.text(fake.inviteUrl(5)), findsOneWidget);
    });

    testWidgets('the host resets the link after confirming', (tester) async {
      final fake = _hostOfFutsal();
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/members'));

      await tester.tap(find.text('Reset link'));
      await tester.pumpAndSettle();
      expect(find.text('Reset link undangan?'), findsOneWidget);
      expect(fake.calls('POST /api/groups/5/invite/reset'), isEmpty);

      await tester.tap(find.text('Ya, reset'));
      await tester.pumpAndSettle();

      expect(fake.calls('POST /api/groups/5/invite/reset'), hasLength(1));
      expect(find.textContaining('Link baru sudah dibuat'), findsOneWidget);
    });

    testWidgets('cancelling the reset keeps the old link', (tester) async {
      final fake = _hostOfFutsal();
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/members'));

      await tester.tap(find.text('Reset link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Batal'));
      await tester.pumpAndSettle();

      expect(fake.calls('POST /api/groups/5/invite/reset'), isEmpty);
    });
  });

  group('join by invite link', () {
    testWidgets(
      'a logged-in user joins with their name and lands on the group',
      (tester) async {
        final fake = _hostOfFutsal();
        final app = AppHarness(fake);
        await app.pump(tester, app.screenRouter('/join/token-5'));

        final nameField = find.widgetWithText(TextField, 'Namamu di grup');
        expect(
          tester.widget<TextField>(nameField).controller!.text,
          'Budi',
          reason: 'prefilled from the account',
        );
        await tester.enterText(nameField, 'Budi S');
        await tester.pump();
        await tester.tap(find.text('Gabung'));
        await tester.pumpAndSettle();

        expect(fake.calls('POST /api/invites/token-5/join').single.body, {
          'display_name': 'Budi S',
        });
        expect(find.text('Beranda'), findsOneWidget);
      },
    );

    testWidgets('a reset link says it no longer works', (tester) async {
      final fake = _hostOfFutsal()..inviteExpired = true;
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/join/token-5'));

      await tester.tap(find.text('Gabung'));
      await tester.pumpAndSettle();

      expect(find.textContaining('sudah tidak berlaku'), findsOneWidget);
      expect(find.text('Beranda'), findsNothing);
    });

    testWidgets(
      '?claim=<member> asks to take over that name; the host must approve',
      (tester) async {
        final fake = _hostOfFutsal();
        final app = AppHarness(fake);
        await app.pump(tester, app.screenRouter('/join/token-5?claim=9'));

        expect(find.text('Klaim namamu'), findsOneWidget);
        await tester.tap(find.text('Ini aku, ajukan klaim'));
        await tester.pumpAndSettle();

        expect(fake.calls('POST /api/members/9/claim'), hasLength(1));
        expect(fake.calls('POST /api/invites/token-5/join'), isEmpty);
        expect(find.text('Permintaan terkirim'), findsOneWidget);
        expect(find.textContaining('Host perlu menyetujui'), findsOneWidget);
      },
    );

    testWidgets('a claim someone else already made is explained', (
      tester,
    ) async {
      final fake = _hostOfFutsal()..claimError = 'claim_pending';
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/join/token-5?claim=9'));

      await tester.tap(find.text('Ini aku, ajukan klaim'));
      await tester.pumpAndSettle();

      expect(
        find.text(Sample.error('claim_pending').json['message'] as String),
        findsOneWidget,
      );
      expect(find.text('Permintaan terkirim'), findsNothing);
    });

    testWidgets('a link opened while logged out continues after login', (
      tester,
    ) async {
      final fake = _hostOfFutsal();
      final app = AppHarness(fake, signedIn: false);
      final router = app.appRouter;
      await app.pump(tester, router);
      router.go('/join/token-5');
      await tester.pumpAndSettle();
      expect(find.text('Masuk ke Petepete'), findsOneWidget);

      await app.auth.requestOtp('6281234567890');
      await app.auth.verifyOtp('123456');
      await tester.pumpAndSettle();

      expect(find.text('Gabung ke grup'), findsOneWidget);
    });
  });

  group('handoff from the web join page', () {
    for (final url in [
      'https://petepete.test/join/token-5?claim=9',
      'petepete://join/token-5?claim=9',
    ]) {
      testWidgets('$url opens the claim screen for that member', (
        tester,
      ) async {
        final fake = _hostOfFutsal();
        final app = AppHarness(fake);
        await app.pump(tester, app.appRouter);
        expect(find.text('Klaim namamu'), findsNothing);

        await _openLink(tester, url);

        expect(find.text('Klaim namamu'), findsOneWidget);
        await tester.tap(find.text('Ini aku, ajukan klaim'));
        await tester.pumpAndSettle();
        expect(fake.calls('POST /api/members/9/claim'), hasLength(1));
        expect(fake.calls('POST /api/invites/token-5/join'), isEmpty);
      });
    }

    testWidgets('petepete://join/<token> without claim opens the plain join', (
      tester,
    ) async {
      final app = AppHarness(_hostOfFutsal());
      await app.pump(tester, app.appRouter);

      await _openLink(tester, 'petepete://join/token-5');

      expect(find.text('Gabung ke grup'), findsOneWidget);
      expect(find.text('Klaim namamu'), findsNothing);
    });

    testWidgets('the app launched by the custom scheme lands on the claim', (
      tester,
    ) async {
      tester.platformDispatcher.defaultRouteNameTestValue =
          'petepete://join/token-5?claim=9';
      addTearDown(tester.platformDispatcher.clearDefaultRouteNameTestValue);
      final app = AppHarness(_hostOfFutsal());
      await app.pump(tester, app.appRouter);

      expect(find.text('Klaim namamu'), findsOneWidget);
    });

    testWidgets('a custom-scheme link opened logged out continues after login '
        'with the claim intact', (tester) async {
      final app = AppHarness(_hostOfFutsal(), signedIn: false);
      await app.pump(tester, app.appRouter);

      await _openLink(tester, 'petepete://join/token-5?claim=9');
      expect(find.text('Masuk ke Petepete'), findsOneWidget);

      await app.auth.requestOtp('6281234567890');
      await app.auth.verifyOtp('123456');
      await tester.pumpAndSettle();

      expect(find.text('Klaim namamu'), findsOneWidget);
    });
  });
}
