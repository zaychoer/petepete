import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_session_server.dart';
import '../../support/sample.dart';

FakeSessionServer _server() {
  final s = FakeSessionServer();
  s.participants[1] = {'attended': true, 'weight': 1000};
  s.participants[2] = {'attended': true, 'weight': 1000};
  return s;
}

void main() {
  late FakeLauncher launcher;
  setUp(() => launcher = FakeLauncher());

  group('cost entry', () {
    testWidgets('chip, nominal, Simpan: two taps and the header updates', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      expect(find.byKey(const Key('header-total')), findsOneWidget);
      expect(find.text('Rp0'), findsOneWidget);

      var taps = 0;
      await tester.tap(find.byKey(const Key('chip-Lapangan')));
      taps++;
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cost-amount')), '350000');
      await tester.tap(find.byKey(const Key('cost-save')));
      taps++;
      await tester.pumpAndSettle();

      expect(taps, lessThanOrEqualTo(3));
      final body = server.bodies['PUT /api/sessions/10/costs/new']!.single;
      expect(body['amount'], 350000);
      expect(body['label'], 'Lapangan');
      expect(body['category'], 'Lapangan');
      expect(body['scope'], 'all');
      expect(find.text('Rp350.000'), findsWidgets);
      expect(
        tester.widget<Text>(find.byKey(const Key('header-total'))).data,
        'Rp350.000',
      );
      // Two people attend: the estimate is the average share.
      expect(
        tester.widget<Text>(find.byKey(const Key('header-per-person'))).data,
        '≈ Rp175.000',
      );
    });

    testWidgets('the payer is the host unless changed, and is shown', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);

      await tester.tap(find.byKey(const Key('chip-Lapangan')));
      await tester.pumpAndSettle();
      expect(find.text('Budi (kamu)'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('cost-amount')), '100000');
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(
        server.bodies['PUT /api/sessions/10/costs/new']!.single['paid_by'],
        1,
      );
      expect(find.text('Dibayar oleh Budi'), findsOneWidget);

      await tester.tap(find.byKey(const Key('chip-Minum')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cost-amount')), '60000');
      await tester.tap(find.byKey(const Key('cost-payer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sari').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();

      expect(
        server.bodies['PUT /api/sessions/10/costs/new']!.last['paid_by'],
        2,
      );
      expect(find.text('Dibayar oleh Sari'), findsOneWidget);
    });

    testWidgets('a nominal of zero is refused before any request', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      await tester.tap(find.byKey(const Key('chip-Lapangan')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cost-amount')), '0');
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(find.text('Nominal harus lebih dari Rp0.'), findsOneWidget);
      expect(server.log, isNot(contains('PUT /api/sessions/10/costs/new')));
    });

    testWidgets('a server refusal stays in the sheet with its message', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      server.fail(
        'PUT /api/sessions/10/costs/new',
        409,
        'session_not_editable',
      );
      await tester.tap(find.byKey(const Key('chip-Lapangan')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cost-amount')), '1000');
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          Sample.error('session_not_editable').json['message'] as String,
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('cost-save')), findsOneWidget);
    });
  });

  group('subset items', () {
    testWidgets('Hanya untuk… sends the ticked members', (tester) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      await tester.tap(find.byKey(const Key('chip-Minum')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cost-amount')), '60000');
      expect(find.byKey(const Key('subset-2')), findsNothing);
      await tester.tap(find.byKey(const Key('subset-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('subset-2')));
      await tester.tap(find.byKey(const Key('subset-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();

      final body = server.bodies['PUT /api/sessions/10/costs/new']!.single;
      expect(body['scope'], 'subset');
      expect(body['members'], [2, 3]);
      expect(find.textContaining('Hanya untuk Sari, Andi'), findsOneWidget);
    });

    testWidgets('an item nobody present bears blocks the bill and says why', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      // Andi is not present, and the drink is only for Andi.
      await tester.tap(find.byKey(const Key('chip-Minum')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cost-amount')), '60000');
      await tester.tap(find.byKey(const Key('subset-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('subset-3')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Belum ada peserta hadir yang menanggung "Minum"'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('open-preview')));
      await tester.pumpAndSettle();
      expect(find.text('Tagihan belum bisa dikirim'), findsOneWidget);
      expect(
        find.textContaining('Pos "Minum" belum ada peserta hadir'),
        findsOneWidget,
      );
      expect(find.text('Kirim tagihan'), findsNothing);

      // Andi checks in: the preview no longer has a problem.
      server.previewJson = previewBody(
        totals: {
          'total_cost': 60000,
          'total_billed': 60000,
          'kas_remainder': 0,
          'credit_used': 0,
          'total_due': 60000,
        },
      );
      await tester.tap(find.text('Kembali dan perbaiki'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('attend-3')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Belum ada peserta hadir yang menanggung'),
        findsNothing,
      );
    });
  });

  group('attendance', () {
    testWidgets('toggling a member sends attended and refreshes', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      expect(
        tester.widget<Switch>(find.byKey(const Key('attend-3'))).value,
        false,
      );
      await tester.tap(find.byKey(const Key('attend-3')));
      await tester.pumpAndSettle();
      expect(server.bodies['PUT /api/sessions/10/attendance']!.single, {
        'member_id': 3,
        'attended': true,
      });
      expect(
        tester.widget<Switch>(find.byKey(const Key('attend-3'))).value,
        true,
      );
    });

    testWidgets('weights show as 1×, 1,2× and 0,5×, stored per mil', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      expect(
        find.descendant(
          of: find.byKey(const Key('weight-1')),
          matching: find.text('1×'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('weight-2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('weight-input')), '1,2');
      await tester.tap(find.byKey(const Key('weight-save')));
      await tester.pumpAndSettle();
      expect(
        server.bodies['PUT /api/sessions/10/attendance']!.single['weight'],
        1200,
      );
      expect(find.text('1,2×'), findsOneWidget);

      await tester.tap(find.byKey(const Key('weight-1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('weight-input')), '0,5');
      await tester.tap(find.byKey(const Key('weight-save')));
      await tester.pumpAndSettle();
      expect(
        server.bodies['PUT /api/sessions/10/attendance']!.last['weight'],
        500,
      );
      expect(find.text('0,5×'), findsOneWidget);
    });

    testWidgets('weight 0 is rejected and nothing is sent', (tester) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      await tester.tap(find.byKey(const Key('weight-2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('weight-input')), '0');
      await tester.tap(find.byKey(const Key('weight-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bobot harus lebih dari 0'), findsOneWidget);
      expect(server.log, isNot(contains('PUT /api/sessions/10/attendance')));
    });

    testWidgets('Tambah tamu on the same screen adds a present guest', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      await tester.tap(find.byKey(const Key('add-guest')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('guest-name')), 'Joni');
      await tester.tap(find.byKey(const Key('guest-save')));
      await tester.pumpAndSettle();

      expect(server.bodies['POST /api/groups/1/guests']!.single, {
        'name': 'Joni',
      });
      expect(server.bodies['PUT /api/sessions/10/attendance']!.single, {
        'member_id': 51,
        'attended': true,
      });
      expect(find.text('Joni (tamu)'), findsOneWidget);
      expect(
        tester.widget<Switch>(find.byKey(const Key('attend-51'))).value,
        true,
      );
    });

    testWidgets('a guest needs a name', (tester) async {
      final server = _server();
      await pumpSession(tester, server, launcher);
      await tester.tap(find.byKey(const Key('add-guest')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('guest-save')));
      await tester.pumpAndSettle();
      expect(find.text('Nama tamu harus diisi.'), findsOneWidget);
      expect(server.log, isNot(contains('POST /api/groups/1/guests')));
    });
  });
}
