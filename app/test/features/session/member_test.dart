import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_session_server.dart';

const _hostOnlyRoutes = [
  'GET /api/sessions/10/share/bills',
  'GET /api/sessions/10/share/reminder',
  'GET /api/sessions/10/preview',
];

FakeSessionServer _server({String role = 'member', String status = 'draft'}) {
  final s = FakeSessionServer()
    ..youRole = role
    ..youMemberId = role == 'host' ? FakeSessionServer.hostId : 2
    ..status = status
    ..progress = status;
  s.participants[1] = {'attended': true, 'weight': 1000};
  s.participants[2] = {'attended': true, 'weight': 1200};
  s.participants[3] = {'attended': false, 'weight': 1000};
  s.costs.add({
    'id': 101,
    'session_id': 10,
    'category': 'Lapangan',
    'label': 'Sewa lapangan',
    'amount': 100000,
    'paid_by': 1,
    'scope': 'all',
  });
  s.summaryJson = {
    'session_id': 10,
    'text': 'Ringkasan Badminton\nSari: Rp50.000 (Lunas)',
    'share_url': 'https://wa.me/?text=Ringkasan',
    'total_cost': 100000,
    'total_billed': 100000,
    'kas_remainder': 0,
    'paid_count': 1,
    'unpaid_count': 1,
  };
  s.shareBills = [
    {
      'bill_id': 1,
      'member_id': 2,
      'display_name': 'Sari',
      'status': 'unpaid',
      'amount_due': 50000,
      'paid_via': null,
      'paid_at': null,
      'cash_cancellable': false,
      'has_phone': false,
      'wa_number': null,
      'text': 'Halo Sari',
      'share_url': 'https://wa.me/?text=Halo',
    },
  ];
  return s;
}

void main() {
  late FakeLauncher launcher;
  setUp(() => launcher = FakeLauncher());

  group('a member opening a draft session', () {
    testWidgets('sees costs and attendance but no edit controls', (
      tester,
    ) async {
      final server = _server();
      await pumpSession(tester, server, launcher);

      expect(find.text('Sewa lapangan'), findsOneWidget);
      expect(find.text('Dibayar oleh Budi'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('header-total'))).data,
        'Rp100.000',
      );
      expect(find.byKey(const Key('attendance-2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('attendance-2')),
          matching: find.text('1,2×'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('attendance-3')),
          matching: find.text('Tidak'),
        ),
        findsOneWidget,
      );

      expect(find.byKey(const Key('chip-Lapangan')), findsNothing);
      expect(find.byKey(const Key('add-guest')), findsNothing);
      expect(find.byKey(const Key('open-preview')), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.byTooltip('Hapus Sewa lapangan'), findsNothing);
    });

    testWidgets('never calls a host-only endpoint', (tester) async {
      final server = _server();
      await pumpSession(tester, server, launcher);

      expect(
        server.log,
        containsAll(['GET /api/groups/1', 'GET /api/sessions/10']),
      );
      for (final route in _hostOnlyRoutes) {
        expect(server.log, isNot(contains(route)));
      }
      expect(server.log.where((l) => !l.startsWith('GET')), isEmpty);
      expect(find.textContaining('ditolak'), findsNothing);
    });
  });

  group('a member opening an issued session', () {
    testWidgets('reads the group summary and gets no bill or share actions', (
      tester,
    ) async {
      final server = _server(status: 'issued');
      await pumpSession(tester, server, launcher);

      expect(find.textContaining('Ringkasan Badminton'), findsOneWidget);
      expect(find.textContaining('Sari: Rp50.000 (Lunas)'), findsOneWidget);
      expect(server.log, contains('GET /api/sessions/10/share/summary'));
      for (final route in _hostOnlyRoutes) {
        expect(server.log, isNot(contains(route)));
      }
      expect(find.byKey(const Key('share-bills')), findsNothing);
      expect(find.byKey(const Key('share-reminder')), findsNothing);
      expect(find.byKey(const Key('void-issue')), findsNothing);
      expect(find.byKey(const Key('bill-paid-1')), findsNothing);
      expect(find.text('Tandai lunas'), findsNothing);
    });

    testWidgets('a failed summary can be retried', (tester) async {
      final server = _server(status: 'issued');
      server.failures['GET /api/sessions/10/share/summary'] = (
        500,
        {'error': 'server_error'},
      );
      await pumpSession(tester, server, launcher);
      expect(find.byKey(const Key('summary-retry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('summary-retry')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Ringkasan Badminton'), findsOneWidget);
    });
  });

  testWidgets(
    'a member opening a cancelled session sees that it is cancelled',
    (tester) async {
      final server = _server(status: 'cancelled');
      await pumpSession(tester, server, launcher);

      expect(find.textContaining('tidak ada tagihan'), findsOneWidget);
      expect(server.log, isNot(contains('GET /api/sessions/10/share/summary')));
    },
  );

  group('the host keeps the full screen', () {
    testWidgets('a draft has the edit controls', (tester) async {
      final server = _server(role: 'host');
      await pumpSession(tester, server, launcher);

      expect(find.byKey(const Key('chip-Lapangan')), findsOneWidget);
      expect(find.byKey(const Key('add-guest')), findsOneWidget);
      expect(find.byKey(const Key('open-preview')), findsOneWidget);
      expect(find.byKey(const Key('attend-2')), findsOneWidget);
      expect(find.byTooltip('Hapus Sewa lapangan'), findsOneWidget);
    });

    testWidgets('an issued session loads the bills, not the member summary', (
      tester,
    ) async {
      final server = _server(role: 'host', status: 'issued');
      await pumpSession(tester, server, launcher);

      expect(server.log, contains('GET /api/sessions/10/share/bills'));
      expect(server.log, isNot(contains('GET /api/sessions/10/share/summary')));
      expect(find.byKey(const Key('bill-paid-1')), findsOneWidget);
      expect(find.byKey(const Key('void-issue')), findsOneWidget);
    });
  });
}
