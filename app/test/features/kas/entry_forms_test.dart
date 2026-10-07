import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_kas_api.dart';

final _amountField = find.widgetWithText(TextField, 'Nominal (Rp)');
final _dropdowns = find.byType(DropdownButtonFormField<int>);

Future<void> _pick(WidgetTester tester, int dropdownIndex, String name) async {
  await tester.tap(_dropdowns.at(dropdownIndex));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> _enterAmount(WidgetTester tester, String text) async {
  await tester.enterText(_amountField, text);
  await tester.pump();
}

Finder _submitFinder(String label) => find.widgetWithText(FilledButton, label);

FilledButton _submitButton(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

void main() {
  group('Catat pelunasan', () {
    Future<void> open(WidgetTester tester, FakeKasApi fake) async {
      await pumpKas(tester, fake);
      await tester.tap(find.text('Catat pelunasan'));
      await tester.pumpAndSettle();
    }

    testWidgets('only a positive whole amount and two different people post', (
      tester,
    ) async {
      final fake = FakeKasApi();
      await open(tester, fake);
      expect(_submitButton(tester, 'Catat pelunasan').onPressed, isNull);

      await _pick(tester, 1, 'Andi');
      await _enterAmount(tester, '0');
      expect(find.text('Nominal harus lebih dari Rp0.'), findsOneWidget);
      expect(_submitButton(tester, 'Catat pelunasan').onPressed, isNull);

      await _enterAmount(tester, '50000');
      expect(_submitButton(tester, 'Catat pelunasan').onPressed, isNotNull);

      // Digits only: a decimal point or letters never reach the amount.
      await _enterAmount(tester, '12.5ab');
      expect(tester.widget<TextField>(_amountField).controller!.text, '125');

      // Payer and payee must differ.
      await _enterAmount(tester, '50000');
      await _pick(tester, 0, 'Andi');
      expect(
        find.text('Pembayar dan penerima tidak boleh orang yang sama.'),
        findsOneWidget,
      );
      expect(_submitButton(tester, 'Catat pelunasan').onPressed, isNull);
      expect(fake.posts, isEmpty);
    });

    testWidgets(
      '"Saya ganti talangan Andi Rp50.000" posts and lands in the history',
      (tester) async {
        final fake = FakeKasApi();
        await open(tester, fake);

        await _pick(tester, 1, 'Andi');
        await _enterAmount(tester, '50000');
        expect(find.text('Saya ganti talangan Andi Rp50.000'), findsOneWidget);

        await tester.tap(_submitFinder('Catat pelunasan'));
        await tester.pumpAndSettle();

        expect(fake.posts.single.path, '/api/groups/1/settlements');
        expect(fake.posts.single.body, {
          'from_member_id': 1,
          'to_member_id': 2,
          'amount': 50000,
        });
        expect(fake.posts.single.key, isNotEmpty);
        // Back on Kas & riwayat, refreshed.
        expect(find.text('Kas & riwayat'), findsOneWidget);
        expect(find.text('Budi bayar Rp50.000 ke Andi'), findsOneWidget);
      },
    );

    testWidgets('a retry after a lost response reuses the key: one txn', (
      tester,
    ) async {
      final fake = FakeKasApi()
        ..failNextPosts = 1
        ..dropAfterPosting = true;
      await open(tester, fake);
      await _pick(tester, 1, 'Citra');
      await _enterAmount(tester, '20000');

      await tester.tap(_submitFinder('Catat pelunasan'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tidak bisa terhubung'), findsOneWidget);

      await tester.tap(_submitFinder('Catat pelunasan'));
      await tester.pumpAndSettle();

      expect(fake.posts, hasLength(2));
      expect(fake.posts[1].key, fake.posts[0].key);
      expect(fake.ledgerTxnCount, 1);
    });

    testWidgets('changing the amount after a failure starts a new key', (
      tester,
    ) async {
      final fake = FakeKasApi()..failNextPosts = 1;
      await open(tester, fake);
      await _pick(tester, 1, 'Citra');
      await _enterAmount(tester, '20000');
      await tester.tap(_submitFinder('Catat pelunasan'));
      await tester.pumpAndSettle();

      await _enterAmount(tester, '25000');
      await tester.tap(_submitFinder('Catat pelunasan'));
      await tester.pumpAndSettle();

      expect(fake.posts[1].key, isNot(fake.posts[0].key));
      expect(fake.posts[1].body['amount'], 25000);
    });

    testWidgets(
      'a refusal shows the server message, or ours when it sends none',
      (tester) async {
        final fake = FakeKasApi();
        await open(tester, fake);
        await _pick(tester, 1, 'Andi');
        await _enterAmount(tester, '5000');

        fake.failNextWith = (
          status: 422,
          code: 'member_not_in_group',
          message: 'Anggota itu bukan bagian dari grup ini.',
        );
        await tester.tap(_submitFinder('Catat pelunasan'));
        await tester.pumpAndSettle();
        expect(
          find.text('Anggota itu bukan bagian dari grup ini.'),
          findsOneWidget,
        );

        fake.failNextWith = (status: 403, code: 'forbidden', message: null);
        await tester.tap(_submitFinder('Catat pelunasan'));
        await tester.pumpAndSettle();
        expect(find.text('Kamu tidak punya akses untuk ini.'), findsOneWidget);
        expect(
          find.text('Anggota itu bukan bagian dari grup ini.'),
          findsNothing,
        );
        expect(fake.ledgerTxnCount, 0);
      },
    );
  });

  group('Belanja dari kas', () {
    Future<void> open(WidgetTester tester, FakeKasApi fake) async {
      await pumpKas(tester, fake);
      await tester.tap(find.text('Belanja dari kas'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      '"Beli bola Rp120.000 dari kas" posts the buyer, amount and note',
      (tester) async {
        final fake = FakeKasApi()..kas = 200000;
        await open(tester, fake);

        await tester.enterText(
          find.widgetWithText(TextField, 'Beli apa? (misal: bola)'),
          'bola',
        );
        await _enterAmount(tester, '120000');
        expect(find.text('Beli bola Rp120.000 dari kas'), findsOneWidget);
        await tester.tap(find.text('Catat belanja'));
        await tester.pumpAndSettle();

        expect(fake.posts.single.path, '/api/groups/1/kas-spends');
        expect(fake.posts.single.body, {
          'member_id': 1,
          'amount': 120000,
          'note': 'bola',
        });
        expect(find.text('Budi beli bola Rp120.000 pakai kas'), findsOneWidget);
        expect(find.text('Rp80.000'), findsOneWidget);
      },
    );

    testWidgets('above the kas balance the server message is shown', (
      tester,
    ) async {
      final fake = FakeKasApi()..kas = 50000;
      await open(tester, fake);

      await _enterAmount(tester, '60000');
      await tester.tap(find.text('Catat belanja'));
      await tester.pumpAndSettle();

      expect(
        find.text('Saldo kas tidak cukup untuk belanja ini.'),
        findsOneWidget,
      );
      expect(find.text('Belanja dari kas'), findsWidgets);
      expect(fake.ledgerTxnCount, 0);
    });

    testWidgets('zero is rejected before any request', (tester) async {
      final fake = FakeKasApi()..kas = 50000;
      await open(tester, fake);

      await _enterAmount(tester, '0');

      expect(find.text('Nominal harus lebih dari Rp0.'), findsOneWidget);
      expect(_submitButton(tester, 'Catat belanja').onPressed, isNull);
      expect(fake.posts, isEmpty);
    });
  });
}
