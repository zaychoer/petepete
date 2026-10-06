import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_session_server.dart';

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
    shareBill(1, 'Sari', 'unpaid', 50000),
    shareBill(2, 'Andi', 'paid', 30000),
    shareBill(3, 'Rina', 'needs_review', 20000),
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

  testWidgets('a settled session reads Selesai', (tester) async {
    final server = _issued();
    server.progress = 'settled';
    await pumpSession(tester, server, launcher);
    expect(find.text('Selesai'), findsOneWidget);
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
    server.failServer('POST /api/bills/2/cash/cancel');
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
    server.fail('POST /api/bills/2/cash/cancel', 422, 'undo_window_expired');
    await tester.tap(find.byKey(const Key('bill-cancel-2')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reason-input')), 'Salah');
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();

    expect(find.textContaining('24 jam sudah lewat'), findsOneWidget);
    expect(find.byKey(const Key('reason-input')), findsOneWidget);
  });

  testWidgets('Batal cash shows only where the server says it is cancellable', (
    tester,
  ) async {
    final server = _issued();
    server.shareBills = [
      shareBill(2, 'Andi', 'paid', 30000), // cash, inside 24 hours
      shareBill(4, 'Dewi', 'paid', 10000, paidVia: 'credit'),
      // cash, but past the 24 hour window
      shareBill(
        5,
        'Eko',
        'paid',
        10000,
        paidAt: '2026-10-01T12:00:00Z',
        cashCancellable: false,
      ),
    ];
    await pumpSession(tester, server, launcher);

    expect(find.byKey(const Key('bill-cancel-2')), findsOneWidget);
    expect(find.byKey(const Key('bill-cancel-4')), findsNothing);
    expect(find.byKey(const Key('bill-cancel-5')), findsNothing);
    // All three are still shown as paid.
    expect(find.text('Lunas'), findsNWidgets(3));
  });

  testWidgets('a void bill reads Dibatalkan and has no actions', (
    tester,
  ) async {
    final server = _issued();
    server.shareBills = [
      shareBill(1, 'Sari', 'unpaid', 50000),
      shareBill(6, 'Rina', 'void', 20000),
    ];
    await pumpSession(tester, server, launcher);

    final rina = find.byKey(const Key('bill-6'));
    expect(
      find.descendant(of: rina, matching: find.text('Dibatalkan')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rina, matching: find.byType(TextButton)),
      findsNothing,
    );
    // The live bill keeps its actions.
    expect(find.byKey(const Key('bill-paid-1')), findsOneWidget);

    // The share sheet lists live bills only: a void entry has no text to send.
    await tester.tap(find.byKey(const Key('share-bills')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('share-1')), findsOneWidget);
    expect(find.byKey(const Key('share-6')), findsNothing);
  });

  testWidgets('a session whose bills are all void still lists them', (
    tester,
  ) async {
    final server = _issued();
    server.shareBills = [
      shareBill(6, 'Rina', 'void', 20000),
      shareBill(7, 'Sari', 'void', 50000),
    ];
    await pumpSession(tester, server, launcher);

    expect(find.text('Tagihan'), findsOneWidget);
    expect(find.text('Dibatalkan'), findsNWidgets(2));
    expect(find.text('Rina'), findsOneWidget);
    expect(find.text('Sari'), findsOneWidget);
    // Nothing live to pay, remind or cancel.
    expect(find.byKey(const Key('share-bills')), findsNothing);
    expect(find.byKey(const Key('void-issue')), findsNothing);
    expect(find.byKey(const Key('bill-paid-6')), findsNothing);
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
