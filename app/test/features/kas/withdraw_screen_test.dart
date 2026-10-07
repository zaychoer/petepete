import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/ui/status_chip.dart';

import '../../support/fake_kas_api.dart';
import '../../support/sample.dart';
import '../../support/wire_labels.dart';

const _location = '/groups/1/withdraw';
final _amountField = find.widgetWithText(TextField, 'Mau tarik berapa? (Rp)');
final _withdrawButton = find.widgetWithText(FilledButton, 'Tarik dana');

Future<void> _enterAmount(WidgetTester tester, String text) async {
  await tester.enterText(_amountField, text);
  await tester.pump();
}

String _serverMessage(String code) =>
    Sample.error(code).json['message'] as String;

void main() {
  testWidgets('shows the sub-account balance, the target account and history', (
    tester,
  ) async {
    final fake = FakeKasApi();
    fake.addWithdrawal(
      id: 5,
      amount: 100000,
      status: 'submitted',
      providerRef: 'po-1',
      insertedAt: DateTime.utc(2026, 10, 1, 3),
    );
    await pumpKas(tester, fake, location: _location);

    expect(find.text('Rp250.000'), findsOneWidget);
    expect(find.textContaining('BCA ••••4321'), findsOneWidget);
    expect(find.text('Rp100.000'), findsOneWidget);
    expect(find.text(WireLabels.withdrawal('submitted')), findsOneWidget);
  });

  testWidgets('withdraws to the registered account and refreshes the balance', (
    tester,
  ) async {
    final fake = FakeKasApi();
    await pumpKas(tester, fake, location: _location);

    await _enterAmount(tester, '100000');
    await tester.tap(_withdrawButton);
    await tester.pump(); await tester.pump(const Duration(milliseconds: 16));

    expect(fake.posts.single.path, '/api/groups/1/withdrawals');
    expect(fake.posts.single.body, {'amount': 100000});
    expect(fake.posts.single.key, isNotEmpty);
    expect(find.text('Penarikan Rp100.000 diajukan.'), findsOneWidget);
    expect(find.text('Rp150.000'), findsOneWidget); // new sub-account balance
    // history row
    expect(find.text(WireLabels.withdrawal('submitted')), findsOneWidget);
    expect(tester.widget<TextField>(_amountField).controller!.text, isEmpty);
  });

  testWidgets('rejects zero and more than the balance before any request', (
    tester,
  ) async {
    final fake = FakeKasApi();
    await pumpKas(tester, fake, location: _location);

    await _enterAmount(tester, '0');
    expect(find.text('Nominal harus lebih dari Rp0.'), findsOneWidget);
    expect(tester.widget<FilledButton>(_withdrawButton).onPressed, isNull);

    await _enterAmount(tester, '250001');
    expect(find.text('Saldo sub-account cuma Rp250.000.'), findsOneWidget);
    expect(tester.widget<FilledButton>(_withdrawButton).onPressed, isNull);

    await _enterAmount(tester, '250000');
    expect(tester.widget<FilledButton>(_withdrawButton).onPressed, isNotNull);
    expect(fake.posts, isEmpty);
  });

  testWidgets('a retry after a lost response reuses the key: one withdrawal', (
    tester,
  ) async {
    final fake = FakeKasApi()
      ..failNextPosts = 1
      ..dropAfterPosting = true;
    await pumpKas(tester, fake, location: _location);

    await _enterAmount(tester, '100000');
    await tester.tap(_withdrawButton);
    await tester.pump(); await tester.pump(const Duration(milliseconds: 16));
    expect(find.textContaining('Tidak bisa terhubung'), findsOneWidget);

    await tester.tap(_withdrawButton);
    await tester.pump(); await tester.pump(const Duration(milliseconds: 16));

    expect(fake.posts, hasLength(2));
    expect(fake.posts[1].key, fake.posts[0].key);
    expect(fake.withdrawals, hasLength(1));
  });

  testWidgets('a server refusal shows its Indonesian message', (tester) async {
    final fake = FakeKasApi();
    await pumpKas(tester, fake, location: _location);
    fake.failNextWith = (status: 422, code: 'insufficient_balance');

    await _enterAmount(tester, '100000');
    await tester.tap(_withdrawButton);
    await tester.pump(); await tester.pump(const Duration(milliseconds: 16));

    expect(find.text(_serverMessage('insufficient_balance')), findsOneWidget);
  });

  group('managed sub-account', () {
    const dashboard = 'https://dashboard.gateway.test/withdraw/abc';

    testWidgets('opens the dashboard URL and lists the withdrawal as pending', (
      tester,
    ) async {
      final fake = FakeKasApi()..managedUrl = dashboard;
      final launched = <Uri>[];
      await pumpKas(tester, fake, location: _location, launched: launched);

      await _enterAmount(tester, '100000');
      await tester.tap(_withdrawButton);
      await tester.pump(); await tester.pump(const Duration(milliseconds: 16));

      expect(launched, [Uri.parse(dashboard)]);
      expect(
        find.textContaining('perlu diselesaikan di dashboard gateway'),
        findsOneWidget,
      );
      expect(find.text(WireLabels.withdrawal('managed')), findsOneWidget);

      // The history row can open it again.
      await tester.tap(find.text('Buka dashboard'));
      await tester.pump(); await tester.pump(const Duration(milliseconds: 16));
      expect(launched, hasLength(2));
    });

    testWidgets('when nothing can open the link, it is shown to copy', (
      tester,
    ) async {
      final fake = FakeKasApi()..managedUrl = dashboard;
      await pumpKas(
        tester,
        fake,
        location: _location,
        launched: [],
        launcherResult: false,
      );

      await _enterAmount(tester, '100000');
      await tester.tap(_withdrawButton);
      await tester.pump(); await tester.pump(const Duration(milliseconds: 16));

      expect(find.textContaining('gagal dibuka otomatis'), findsOneWidget);
      expect(find.text(dashboard), findsOneWidget);
    });
  });

  testWidgets('a host who does not own the payout account cannot withdraw', (
    tester,
  ) async {
    final fake = FakeKasApi()..payoutOwner = false;
    await pumpKas(tester, fake, location: _location);

    expect(find.text('Rp250.000'), findsOneWidget);
    expect(find.textContaining('Cuma pemilik rekening'), findsOneWidget);
    expect(_amountField, findsNothing);
    expect(_withdrawButton, findsNothing);
  });

  testWidgets('an account that is not active yet says why', (tester) async {
    final fake = FakeKasApi()..payoutStatus = 'pending_kyc';
    await pumpKas(tester, fake, location: _location);

    expect(find.textContaining('belum aktif'), findsOneWidget);
    expect(_withdrawButton, findsNothing);
  });

  testWidgets('without a payout account it points to registering one', (
    tester,
  ) async {
    final fake = FakeKasApi()..hasPayoutAccount = false;
    await pumpKas(tester, fake, location: _location);

    expect(find.text(_serverMessage('no_payout_account')), findsOneWidget);
    await tester.tap(find.text('Daftarkan rekening pencairan'));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('Daftar rekening pencairan'), findsOneWidget);
  });

  testWidgets('a needs_review withdrawal shows the label and a warning chip', (
    tester,
  ) async {
    final fake = FakeKasApi();
    fake.addWithdrawal(
      id: 99,
      amount: 50000,
      status: 'needs_review',
      insertedAt: DateTime.utc(2026, 10, 2),
    );
    await pumpKas(tester, fake, location: _location);

    expect(find.text(WireLabels.withdrawal('needs_review')), findsOneWidget);
    final chip = tester.widget<StatusChip>(
      find.widgetWithText(StatusChip, WireLabels.withdrawal('needs_review')),
    );
    expect(chip.tone, StatusTone.warning);
  });

  testWidgets('Kas & riwayat links the host to Tarik dana', (tester) async {
    final fake = FakeKasApi();
    await pumpKas(tester, fake);

    await tester.tap(find.text('Tarik dana'));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 16));

    expect(find.text('Saldo sub-account'), findsOneWidget);
  });
}
