import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_session_server.dart';

Map<String, dynamic> _bill(int id, String name, String status, int due) => {
  'bill_id': id,
  'member_id': id + 10,
  'display_name': name,
  'status': status,
  'amount_due': due,
  'has_phone': false,
  'wa_number': null,
  'text': 'Halo $name',
  'share_url': 'https://wa.me/?text=Halo',
};

FakeSessionServer _issued() {
  final s = FakeSessionServer();
  s.status = 'issued';
  s.progress = 'issued';
  s.costs.add({
    'id': 101,
    'session_id': 10,
    'category': 'Lapangan',
    'label': 'Lapangan',
    'amount': 100000,
    'paid_by': 1,
    'scope': 'all',
  });
  s.shareBills = [
    _bill(1, 'Sari', 'unpaid', 50000),
    _bill(2, 'Andi', 'paid', 30000),
    _bill(3, 'Rina', 'needs_review', 20000),
  ];
  return s;
}

void main() {
  late FakeLauncher launcher;
  setUp(() => launcher = FakeLauncher());

  testWidgets('every status is shown with its text label', (tester) async {
    final server = _issued();
    await pumpSession(tester, server, launcher);

    expect(find.text('Ditagih'), findsOneWidget); // session chip
    final sari = find.byKey(const Key('bill-1'));
    final andi = find.byKey(const Key('bill-2'));
    final rina = find.byKey(const Key('bill-3'));
    expect(
      find.descendant(of: sari, matching: find.text('Belum bayar')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: andi, matching: find.text('Lunas')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rina, matching: find.text('Perlu dicek')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sari, matching: find.text('Rp50.000')),
      findsOneWidget,
    );
  });

  testWidgets('a settled session reads Selesai, a cancelled one Batal', (
    tester,
  ) async {
    final server = _issued();
    server.progress = 'settled';
    await pumpSession(tester, server, launcher);
    expect(find.text('Selesai'), findsOneWidget);

    final cancelled = _issued();
    cancelled.status = 'cancelled';
    cancelled.progress = 'cancelled';
    await pumpSession(tester, cancelled, launcher);
    expect(find.text('Batal'), findsOneWidget);
    expect(find.textContaining('tidak ada tagihan'), findsOneWidget);
  });

  testWidgets(
    'Perlu dicek lists the bills to check, Tandai lunas resolves one',
    (tester) async {
      final server = _issued();
      await pumpSession(tester, server, launcher);

      expect(find.text('Perlu dicek (1)'), findsOneWidget);
      expect(find.byKey(const Key('review-3')), findsOneWidget);
      // Paid bills cannot be marked paid again.
      expect(find.byKey(const Key('bill-paid-2')), findsNothing);
      expect(find.byKey(const Key('bill-paid-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('review-paid-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action-confirm')));
      await tester.pumpAndSettle();

      expect(server.keys['POST /api/bills/3/cash']!.single, isNotEmpty);
      expect(find.byKey(const Key('review-3')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('bill-3')),
          matching: find.text('Lunas'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('Batal cash needs a reason and keeps its key across a retry', (
    tester,
  ) async {
    final server = _issued();
    await pumpSession(tester, server, launcher);

    await tester.tap(find.byKey(const Key('bill-cancel-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Alasan wajib diisi.'), findsOneWidget);
    expect(server.log, isNot(contains('POST /api/bills/2/cash/cancel')));

    await tester.enterText(
      find.byKey(const Key('reason-input')),
      'Salah tandai',
    );
    server.failures['POST /api/bills/2/cash/cancel'] = (
      500,
      {'error': 'server_error'},
    );
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Server lagi bermasalah'), findsOneWidget);
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();

    final keys = server.keys['POST /api/bills/2/cash/cancel']!;
    expect(keys, hasLength(2));
    expect(keys.first, keys.last);
    expect(server.bodies['POST /api/bills/2/cash/cancel']!.last, {
      'reason': 'Salah tandai',
    });
    expect(
      find.descendant(
        of: find.byKey(const Key('bill-2')),
        matching: find.text('Belum bayar'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('undo_window_expired is explained in Indonesian', (tester) async {
    final server = _issued();
    await pumpSession(tester, server, launcher);
    server.failures['POST /api/bills/2/cash/cancel'] = (
      422,
      {'error': 'undo_window_expired'},
    );
    await tester.tap(find.byKey(const Key('bill-cancel-2')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reason-input')), 'Salah');
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('24 jam sudah lewat'), findsOneWidget);
    expect(find.byKey(const Key('reason-input')), findsOneWidget);
  });

  testWidgets('Batalkan tagihan requires a reason and explains credit', (
    tester,
  ) async {
    final server = _issued();
    await pumpSession(tester, server, launcher);

    await tester.ensureVisible(find.byKey(const Key('void-issue')));
    await tester.tap(find.byKey(const Key('void-issue')));
    await tester.pumpAndSettle();
    expect(find.textContaining('jadi kredit peserta'), findsOneWidget);

    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('Alasan wajib diisi.'), findsOneWidget);
    expect(server.log, isNot(contains('POST /api/sessions/10/void')));

    await tester.enterText(
      find.byKey(const Key('reason-input')),
      'Salah hitung',
    );
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();

    expect(server.bodies['POST /api/sessions/10/void']!.single, {
      'reason': 'Salah hitung',
    });
    expect(server.keys['POST /api/sessions/10/void']!.single, isNotEmpty);
    // The session is a draft again: costs can be edited.
    expect(find.byKey(const Key('open-preview')), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
  });
}
