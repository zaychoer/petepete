import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_groups_api.dart';

FakeGroupsApi _fake() {
  final fake = FakeGroupsApi();
  fake.groups.add({
    'id': 5,
    'name': 'Futsal Kamis',
    'template': 'Futsal',
    'role': 'host',
  });
  return fake;
}

const _route = '/groups/5/payout-account/register';

Future<void> _fill(
  WidgetTester tester, {
  String number = '1234 567 890',
}) async {
  await tester.enterText(find.widgetWithText(TextField, 'Bank'), 'BCA');
  await tester.enterText(
    find.widgetWithText(TextField, 'Nomor rekening'),
    number,
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Nama pemilik rekening'),
    'Budi Santoso',
  );
}

void main() {
  testWidgets('registering shows the pending status as text', (tester) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter(_route));

    await _fill(tester);
    await tester.tap(find.text('Daftarkan rekening'));
    await tester.pumpAndSettle();

    expect(fake.calls('POST /api/groups/5/payout-account').single.body, {
      'bank_name': 'BCA',
      'account_number': '1234567890',
      'account_holder_name': 'Budi Santoso',
    });
    expect(find.text('Menunggu verifikasi (KYC)'), findsOneWidget);
    expect(find.text('BCA · •••• 7890'), findsOneWidget);
    expect(find.textContaining('belum bisa menarik dana'), findsOneWidget);
    // The full account number is never shown again.
    expect(find.textContaining('1234'), findsNothing);
  });

  testWidgets('a retry after a failure reuses the Idempotency-Key', (
    tester,
  ) async {
    final fake = _fake()..registerFailsOnce = true;
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter(_route));

    await _fill(tester);
    await tester.tap(find.text('Daftarkan rekening'));
    await tester.pumpAndSettle();
    expect(find.text('Menunggu verifikasi (KYC)'), findsNothing);

    await tester.tap(find.text('Daftarkan rekening'));
    await tester.pumpAndSettle();

    expect(find.text('Menunggu verifikasi (KYC)'), findsOneWidget);
    expect(fake.payoutKeys, hasLength(2));
    expect(fake.payoutKeys.first, isNotNull);
    expect(fake.payoutKeys.last, fake.payoutKeys.first);
  });

  testWidgets('an active status reads Aktif', (tester) async {
    final fake = _fake()..registeredStatus = 'active';
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter(_route));

    await _fill(tester);
    await tester.tap(find.text('Daftarkan rekening'));
    await tester.pumpAndSettle();

    expect(find.text('Aktif'), findsOneWidget);
    expect(find.text('Menunggu verifikasi (KYC)'), findsNothing);
  });

  testWidgets(
    'opening it again shows the registered account instead of the form',
    (tester) async {
      final fake = _fake()
        ..payout = {
          'status': 'pending_kyc',
          'bank_name': 'Mandiri',
          'account_last4': '4321',
        };
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter(_route));

      expect(find.text('Menunggu verifikasi (KYC)'), findsOneWidget);
      expect(find.text('Mandiri · •••• 4321'), findsOneWidget);
      expect(find.text('Daftarkan rekening'), findsNothing);
    },
  );

  testWidgets('empty or malformed fields are refused before sending', (
    tester,
  ) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter(_route));

    await tester.tap(find.text('Daftarkan rekening'));
    await tester.pumpAndSettle();
    expect(find.text('Nama bank harus diisi.'), findsOneWidget);
    expect(find.text('Nama pemilik rekening harus diisi.'), findsOneWidget);

    await _fill(tester, number: '12ab');
    await tester.tap(find.text('Daftarkan rekening'));
    await tester.pumpAndSettle();
    expect(
      find.text('Nomor rekening harus berupa angka, minimal 6 digit.'),
      findsOneWidget,
    );
    expect(fake.calls('POST /api/groups/5/payout-account'), isEmpty);
  });
}
