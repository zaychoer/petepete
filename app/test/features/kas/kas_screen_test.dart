import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_kas_api.dart';

/// Budi (1, signed in), Andi (2), Citra (3). Andi fronted the court, Citra owes.
FakeKasApi _seeded({bool host = true}) {
  final fake = FakeKasApi(host: host);
  fake.seed('session_billed', 'Tagihan sesi terbit: Rp100.000 untuk 2 orang', [
    (2, 100000),
    (3, -50000),
    (1, -50000),
  ]);
  fake.seed('cash_received', 'Citra bayar Rp20.000 (tunai)', [
    (3, 20000),
    (1, -20000),
  ]);
  fake.seed('settlement', 'Budi bayar Rp30.000 ke Andi', [
    (1, 30000),
    (2, -30000),
  ]);
  fake.kas = 15000;
  return fake;
}

void main() {
  group('Kas & riwayat', () {
    testWidgets('shows saldo kas, per-member balance in words, and history', (
      tester,
    ) async {
      final fake = _seeded();
      fake.balances[1] = -40000;
      fake.balances[2] = 70000;
      fake.balances[3] = 0;
      await pumpKas(tester, fake);

      expect(find.text('Saldo kas'), findsOneWidget);
      expect(find.text('Rp15.000'), findsOneWidget);
      expect(find.text('Berutang Rp40.000'), findsOneWidget);
      expect(find.text('Kredit Rp70.000'), findsOneWidget);
      expect(find.text('Impas (Rp0)'), findsOneWidget);

      expect(find.text('Budi bayar Rp30.000 ke Andi'), findsOneWidget);
      expect(find.text('Citra bayar Rp20.000 (tunai)'), findsOneWidget);
      expect(
        find.text('Tagihan sesi terbit: Rp100.000 untuk 2 orang'),
        findsOneWidget,
      );
      expect(find.textContaining('6 Okt 2026, '), findsNWidgets(3));
      expect(find.text('Pelunasan'), findsOneWidget); // kind label as text
    });

    testWidgets('a negative kas says so in words', (tester) async {
      final fake = _seeded()..kas = -5000;
      await pumpKas(tester, fake);

      expect(find.text('-Rp5.000'), findsOneWidget);
      expect(find.textContaining('Kas lagi minus'), findsOneWidget);
    });

    testWidgets('filters the history to one member', (tester) async {
      final fake = _seeded();
      await pumpKas(tester, fake);

      await tester.tap(find.byKey(const Key('filter-member')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Citra').last);
      await tester.pumpAndSettle();

      expect(fake.log, contains('GET /api/groups/1/txns?member_id=3'));
      expect(find.text('Citra bayar Rp20.000 (tunai)'), findsOneWidget);
      expect(find.text('Budi bayar Rp30.000 ke Andi'), findsNothing);

      await tester.tap(find.byKey(const Key('filter-member')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Semua anggota').last);
      await tester.pumpAndSettle();
      expect(find.text('Budi bayar Rp30.000 ke Andi'), findsOneWidget);
    });

    testWidgets('a plain member sees the books but no host actions', (
      tester,
    ) async {
      await pumpKas(tester, _seeded(host: false));

      expect(find.text('Budi bayar Rp30.000 ke Andi'), findsOneWidget);
      expect(find.text('Catat pelunasan'), findsNothing);
      expect(find.text('Belanja dari kas'), findsNothing);
      expect(find.text('Tarik dana'), findsNothing);
      expect(find.text('Koreksi'), findsNothing);
    });

    testWidgets('a load failure shows the server message and can retry', (
      tester,
    ) async {
      final fake = _seeded();
      await pumpKas(tester, fake, location: '/groups/9/kas');

      expect(find.text('Data tidak ditemukan.'), findsOneWidget);
      expect(find.text('Coba lagi'), findsOneWidget);
    });
  });

  group('Koreksi', () {
    testWidgets('is offered only on settlement and kas spend txns', (
      tester,
    ) async {
      final fake = _seeded();
      fake.seed('kas_spend', 'Budi beli bola Rp10.000 pakai kas', [
        (null, -10000),
        (1, 10000),
      ]);
      await pumpKas(tester, fake);

      // settlement (txn 3) and kas_spend (txn 4) only; billed (1) and cash (2) not.
      expect(
        find.descendant(
          of: find.byKey(const Key('txn-1')),
          matching: find.text('Koreksi'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('txn-2')),
          matching: find.text('Koreksi'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('txn-3')),
          matching: find.text('Koreksi'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('txn-4')),
          matching: find.text('Koreksi'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('needs a reason, then shows original and reversing entries', (
      tester,
    ) async {
      final fake = _seeded();
      await pumpKas(tester, fake);

      await tester.tap(find.text('Koreksi'));
      await tester.pumpAndSettle();
      final confirm = find.widgetWithText(FilledButton, 'Koreksi');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Salah catat');
      await tester.pump();
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(fake.posts.single.path, '/api/txns/3/correction');
      expect(fake.posts.single.body, {'reason': 'Salah catat'});
      // The original stays, marked, and the reversing txn is listed with its reason.
      expect(find.text('Budi bayar Rp30.000 ke Andi'), findsOneWidget);
      expect(find.text('Sudah dikoreksi'), findsOneWidget);
      expect(
        find.text(
          'Dikoreksi: Budi bayar Rp30.000 ke Andi. Alasan: Salah catat',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Koreksi'),
        findsOneWidget,
      ); // only the kind chip is left
      expect(find.widgetWithText(TextButton, 'Koreksi'), findsNothing);
    });

    testWidgets('shows the server message when it is refused', (tester) async {
      final fake = _seeded();
      await pumpKas(tester, fake);
      // Someone else corrected it meanwhile.
      fake.seed(
        'correction',
        'Dikoreksi: Budi bayar Rp30.000 ke Andi. Alasan: x',
        [(1, -30000), (2, 30000)],
        reverses: 3,
        reason: 'x',
      );

      await tester.tap(find.text('Koreksi'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Salah catat');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Koreksi'));
      await tester.pumpAndSettle();

      expect(find.text('Catatan ini sudah pernah dikoreksi.'), findsOneWidget);
      expect(find.text('Koreksi catatan'), findsOneWidget); // dialog stays open
    });

    testWidgets('a retry after a lost response reuses the key and posts once', (
      tester,
    ) async {
      final fake = _seeded();
      await pumpKas(tester, fake);
      fake.failNextPosts = 1;
      fake.dropAfterPosting = true;

      await tester.tap(find.text('Koreksi'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Salah catat');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Koreksi'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tidak bisa terhubung'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Koreksi'));
      await tester.pumpAndSettle();

      expect(fake.posts, hasLength(2));
      expect(fake.posts[0].key, isNotNull);
      expect(fake.posts[1].key, fake.posts[0].key);
      expect(fake.txns.where((t) => t['kind'] == 'correction'), hasLength(1));
    });
  });
}
