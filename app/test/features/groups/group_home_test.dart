import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_groups_api.dart';

Map<String, dynamic> _bill(int id, String name, String status, int amount) => {
  'id': id,
  'status': status,
  'amount_due': amount,
  'member_id': id,
  'member_name': name,
  'session_id': 11,
  'session_starts_at': '2026-10-08T12:00:00Z',
  'event_name': 'Futsal Kamis',
};

Future<AppHarness> _open(
  WidgetTester tester,
  FakeGroupsApi fake, {
  String role = 'host',
}) async {
  fake.groups.add({
    'id': 5,
    'name': 'Futsal Kamis',
    'template': 'Futsal',
    'role': role,
  });
  final app = AppHarness(fake);
  await app.pump(tester, app.screenRouter('/groups/5'));
  return app;
}

void main() {
  testWidgets(
    'shows the next session, kas balance, unpaid and needs-review lists',
    (tester) async {
      final fake = FakeGroupsApi();
      fake.homes[5] = {
        ...emptyHome(5, 'Futsal Kamis'),
        'next_session': {
          'id': 11,
          'event_id': 2,
          'event_name': 'Futsal Kamis',
          'starts_at': '2026-10-08T12:00:00Z',
          'status': 'issued',
          'progress': 'issued',
          'cost_total': 350000,
          'attended_count': 8,
        },
        'kas_balance': 150000,
        'unpaid_bills': [
          _bill(1, 'Andi', 'unpaid', 45000),
          _bill(2, 'Sari', 'unpaid', 45000),
        ],
        'needs_review_bills': [_bill(3, 'Rudi', 'needs_review', 50000)],
      };
      await _open(tester, fake);

      // 12:00 UTC is 19:00 WIB.
      expect(find.text('Kamis, 8 Okt 2026 · 19:00 WIB'), findsOneWidget);
      expect(find.text('Ditagih'), findsOneWidget); // session status, as text
      expect(find.text('8 hadir · total biaya Rp350.000'), findsOneWidget);
      expect(find.text('Saldo kas'), findsOneWidget);
      expect(find.text('Rp150.000'), findsOneWidget);
      expect(find.text('Belum bayar (2)'), findsOneWidget);
      expect(find.text('Andi'), findsOneWidget);
      expect(find.text('Sari'), findsOneWidget);
      expect(find.text('Perlu dicek (1)'), findsOneWidget);
      expect(find.text('Rudi'), findsOneWidget);
      expect(
        find.text('Belum bayar'),
        findsNWidgets(2),
      ); // the chips, with text
      expect(find.text('Perlu dicek'), findsOneWidget);
      // No phone numbers anywhere.
      expect(find.textContaining('08'), findsNothing);
      expect(find.textContaining('+62'), findsNothing);
    },
  );

  testWidgets('empty group home explains each empty card', (tester) async {
    final fake = FakeGroupsApi();
    fake.homes[5] = emptyHome(5, 'Futsal Kamis');
    await _open(tester, fake);

    expect(
      find.text(
        'Belum ada sesi. Buat event dulu, nanti sesinya muncul di sini.',
      ),
      findsOneWidget,
    );
    expect(find.text('Rp0'), findsOneWidget);
    expect(
      find.text('Tidak ada tagihan yang menunggu pembayaran.'),
      findsOneWidget,
    );
    expect(find.text('Tidak ada pembayaran yang perlu dicek.'), findsOneWidget);
  });

  testWidgets('a member sees the cards but not the host actions', (
    tester,
  ) async {
    final fake = FakeGroupsApi();
    fake.homes[5] = emptyHome(5, 'Futsal Kamis', role: 'member');
    await _open(tester, fake, role: 'member');

    expect(find.text('Belum ada sesi yang dijadwalkan.'), findsOneWidget);
    expect(find.text('Undang'), findsNothing);
    expect(find.text('Buat event'), findsNothing);
  });

  testWidgets('tapping the session card or a bill opens that session', (
    tester,
  ) async {
    final fake = FakeGroupsApi();
    fake.homes[5] = {
      ...emptyHome(5, 'Futsal Kamis'),
      'next_session': {
        'id': 11,
        'event_id': 2,
        'event_name': 'Futsal Kamis',
        'starts_at': '2026-10-08T12:00:00Z',
        'status': 'draft',
        'progress': 'draft',
        'cost_total': 0,
        'attended_count': 0,
      },
      'unpaid_bills': [_bill(1, 'Andi', 'unpaid', 45000)],
    };
    await _open(tester, fake);

    await tester.tap(find.text('Sesi berikutnya'));
    await tester.pumpAndSettle();
    expect(find.text('stub /groups/5/sessions/11'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Andi'));
    await tester.pumpAndSettle();
    expect(find.text('stub /groups/5/sessions/11'), findsOneWidget);
  });

  testWidgets('the kas card opens the kas screen', (tester) async {
    final fake = FakeGroupsApi();
    fake.homes[5] = emptyHome(5, 'Futsal Kamis');
    await _open(tester, fake);

    await tester.tap(find.text('Saldo kas'));
    await tester.pumpAndSettle();

    expect(find.text('stub /groups/5/kas'), findsOneWidget);
  });

  testWidgets('a failed load shows the error and a retry', (tester) async {
    final fake = FakeGroupsApi();
    fake.groups.add({
      'id': 5,
      'name': 'Futsal Kamis',
      'template': 'Futsal',
      'role': 'host',
    });
    // No home for group 5 yet: the fake answers like a server error.
    final app = AppHarness(fake);
    await app.auth.restore();
    fake.homes.remove(5);
    await app.pump(tester, app.screenRouter('/groups/5'), restore: false);
    expect(find.text('Coba lagi'), findsOneWidget);

    fake.homes[5] = emptyHome(5, 'Futsal Kamis');
    await tester.tap(find.text('Coba lagi'));
    await tester.pumpAndSettle();

    expect(find.text('Beranda'), findsOneWidget);
  });
}
