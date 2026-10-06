import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_session_server.dart';

Map<String, dynamic> _line(int id, String label, int amount) => {
  'cost_item_id': id,
  'category': label,
  'label': label,
  'fraction': {'numerator': amount, 'denominator': 1},
  'amount': amount,
};

FakeSessionServer _server() {
  final s = FakeSessionServer();
  s.participants[1] = {'attended': true, 'weight': 1000};
  s.participants[2] = {'attended': true, 'weight': 1200};
  s.costs.add({
    'id': 101,
    'session_id': 10,
    'category': 'Lapangan',
    'label': 'Lapangan',
    'amount': 100000,
    'paid_by': 1,
    'scope': 'all',
  });
  s.previewJson = {
    'total_cost': 100000,
    'total_billed': 101000,
    'kas_remainder': 1000,
    'credit_used': 10000,
    'total_due': 91000,
    'items': [
      {
        'id': 101,
        'category': 'Lapangan',
        'label': 'Lapangan',
        'amount': 100000,
        'paid_by_member_id': 1,
        'scope': 'all',
        'bearer_ids': [1, 2],
        'total_weight': 2200,
      },
    ],
    'members': [
      {
        'member_id': 1,
        'display_name': 'Budi',
        'weight': 1000,
        'lines': [_line(101, 'Lapangan', 45455)],
        'share': 46000,
        'rounding': 545,
        'credit_applied': 10000,
        'amount_due': 36000,
      },
      {
        'member_id': 2,
        'display_name': 'Sari',
        'weight': 1200,
        'lines': [_line(101, 'Lapangan', 54545)],
        'share': 55000,
        'rounding': 455,
        'credit_applied': 0,
        'amount_due': 55000,
      },
    ],
  };
  s.shareBills = [
    {
      'bill_id': 1,
      'member_id': 2,
      'display_name': 'Sari',
      'status': 'unpaid',
      'amount_due': 55000,
      'paid_via': null,
      'paid_at': null,
      'cash_cancellable': false,
      'has_phone': true,
      'wa_number': '6281234567890',
      'text': 'Halo Sari, tagihan Rp55.000 & link: https://pay.test/p/abc',
      'share_url': 'https://wa.me/?text=Halo%20Sari',
    },
    {
      'bill_id': 2,
      'member_id': 3,
      'display_name': 'Andi',
      'status': 'unpaid',
      'amount_due': 20000,
      'paid_via': null,
      'paid_at': null,
      'cash_cancellable': false,
      'has_phone': false,
      'wa_number': null,
      'text': 'Halo Andi, tagihan Rp20.000',
      'share_url': 'https://wa.me/?text=Halo%20Andi%2C%20tagihan%20Rp20.000',
    },
  ];
  s.reminderJson = {
    'session_id': 10,
    'count': 2,
    'group_text': 'Pengingat: Sari, Andi belum bayar',
    'share_url': 'https://wa.me/?text=Pengingat',
    'bills': s.shareBills,
  };
  s.summaryJson = {
    'session_id': 10,
    'text': 'Ringkasan',
    'share_url': 'https://wa.me/?text=Ringkasan',
  };
  return s;
}

Future<void> _openPreview(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open-preview')));
  await tester.pumpAndSettle();
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  late FakeLauncher launcher;
  setUp(() => launcher = FakeLauncher());

  testWidgets('the preview shows exact rupiah per person and per cost item', (
    tester,
  ) async {
    final server = _server();
    await pumpSession(tester, server, launcher);
    await _openPreview(tester);

    expect(_text(tester, 'total-cost'), 'Rp100.000');
    expect(_text(tester, 'total-billed'), 'Rp101.000');
    expect(_text(tester, 'credit-used'), 'Rp10.000');
    expect(_text(tester, 'total-due'), 'Rp91.000');
    expect(_text(tester, 'kas-remainder'), 'Masuk kas: Rp1.000');

    final sari = find.byKey(const Key('member-2'));
    expect(
      find.descendant(of: sari, matching: find.text('Sari (1,2×)')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sari, matching: find.text('Rp54.545')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sari, matching: find.text('Rp455')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sari, matching: find.text('Rp55.000')),
      findsWidgets,
    );

    final budi = find.byKey(const Key('member-1'));
    expect(
      find.descendant(of: budi, matching: find.text('-Rp10.000')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: budi, matching: find.text('Rp36.000')),
      findsOneWidget,
    );
    // The payer is part of the breakdown.
    expect(find.text('Ditalangi Budi'), findsOneWidget);
    expect(find.text('Lapangan (talangan Budi)'), findsNWidgets(2));
  });

  testWidgets('issuing sends one Idempotency-Key, also across a retry, then '
      'offers the WhatsApp actions', (tester) async {
    final server = _server();
    await pumpSession(tester, server, launcher);
    await _openPreview(tester);

    server.failures['POST /api/sessions/10/issue'] = (
      500,
      {'error': 'server_error'},
    );
    await tester.ensureVisible(find.byKey(const Key('issue-button')));
    await tester.tap(find.byKey(const Key('issue-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Server lagi bermasalah'), findsOneWidget);

    await tester.tap(find.byKey(const Key('issue-button')));
    await tester.pumpAndSettle();

    final keys = server.keys['POST /api/sessions/10/issue']!;
    expect(keys, hasLength(2));
    expect(keys.first, isNotNull);
    expect(keys.first, keys.last);

    expect(find.text('Ditagih'), findsOneWidget);
    expect(find.byKey(const Key('share-bills')), findsOneWidget);
    expect(find.byKey(const Key('share-reminder')), findsOneWidget);
    expect(find.byKey(const Key('share-summary')), findsOneWidget);
  });

  testWidgets('a second issue action gets a new key', (tester) async {
    final server = _server();
    await pumpSession(tester, server, launcher);
    await _openPreview(tester);
    await tester.ensureVisible(find.byKey(const Key('issue-button')));
    await tester.tap(find.byKey(const Key('issue-button')));
    await tester.pumpAndSettle();
    // Void, then issue again from a fresh preview screen.
    await tester.tap(find.byKey(const Key('void-issue')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('reason-input')),
      'Salah hitung',
    );
    await tester.tap(find.byKey(const Key('action-confirm')));
    await tester.pumpAndSettle();
    await _openPreview(tester);
    await tester.ensureVisible(find.byKey(const Key('issue-button')));
    await tester.tap(find.byKey(const Key('issue-button')));
    await tester.pumpAndSettle();

    final keys = server.keys['POST /api/sessions/10/issue']!;
    expect(keys, hasLength(2));
    expect(keys.first, isNot(keys.last));
  });

  group('Bagikan ke WA', () {
    Future<FakeSessionServer> issued(WidgetTester tester) async {
      final server = _server();
      server.status = 'issued';
      server.progress = 'issued';
      await pumpSession(tester, server, launcher);
      return server;
    }

    testWidgets('a bill with a number opens a personal wa.me link', (
      tester,
    ) async {
      await issued(tester);
      await tester.ensureVisible(find.byKey(const Key('share-bills')));
      await tester.tap(find.byKey(const Key('share-bills')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kirim WA'));
      await tester.pumpAndSettle();

      final uri = launcher.opened.single;
      expect(uri.scheme, 'https');
      expect(uri.host, 'wa.me');
      expect(uri.path, '/6281234567890');
      expect(
        uri.queryParameters['text'],
        'Halo Sari, tagihan Rp55.000 & link: https://pay.test/p/abc',
      );
      // Spaces and & are percent-encoded, never '+'.
      expect(uri.query, isNot(contains('+')));
      expect(uri.query, isNot(contains(' ')));
      expect(uri.query, isNot(contains('&')));
    });

    testWidgets('a bill without a number goes out as group text', (
      tester,
    ) async {
      await issued(tester);
      await tester.ensureVisible(find.byKey(const Key('share-bills')));
      await tester.tap(find.byKey(const Key('share-bills')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kirim ke grup'));
      await tester.pumpAndSettle();

      expect(
        launcher.opened.single,
        Uri.parse('https://wa.me/?text=Halo%20Andi%2C%20tagihan%20Rp20.000'),
      );
    });

    testWidgets('reminder goes to the group, summary opens its link', (
      tester,
    ) async {
      await issued(tester);
      await tester.ensureVisible(find.byKey(const Key('share-reminder')));
      await tester.tap(find.byKey(const Key('share-reminder')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('share-group')));
      await tester.pumpAndSettle();
      expect(
        launcher.opened.single,
        Uri.parse('https://wa.me/?text=Pengingat'),
      );

      await tester.tapAt(const Offset(10, 10)); // close the sheet
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('share-summary')));
      await tester.pumpAndSettle();
      expect(launcher.opened.last, Uri.parse('https://wa.me/?text=Ringkasan'));
    });

    testWidgets('when WhatsApp cannot open, the host is told', (tester) async {
      await issued(tester);
      launcher.succeeds = false;
      await tester.ensureVisible(find.byKey(const Key('share-summary')));
      await tester.tap(find.byKey(const Key('share-summary')));
      await tester.pumpAndSettle();
      expect(find.textContaining('WhatsApp tidak bisa dibuka'), findsOneWidget);
    });
  });
}
