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
  fake.homes[5] = emptyHome(5, 'Futsal Kamis');
  return fake;
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.text('Simpan event'));
  await tester.pumpAndSettle();
}

String _two(int n) => n.toString().padLeft(2, '0');

void main() {
  testWidgets('everything fits on one screen', (tester) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter('/groups/5/events/new'));

    expect(find.text('Buat event'), findsOneWidget);
    expect(find.text('Rutin'), findsOneWidget);
    expect(find.text('Sekali jalan'), findsOneWidget);
    expect(find.text('Hari main'), findsOneWidget);
    expect(find.text('Jam (WIB)'), findsOneWidget);
    expect(find.text('19:00'), findsOneWidget, reason: 'sensible default time');
    expect(find.text('Biaya default per sesi'), findsOneWidget);
    // The group's template categories are one tap away.
    expect(find.text('+ Sewa lapangan'), findsOneWidget);
    expect(find.text('Simpan event'), findsOneWidget);
  });

  testWidgets(
    'a recurring event needs a weekday; nothing is sent until valid',
    (tester) async {
      final fake = _fake();
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/events/new'));

      await _tapSave(tester);

      expect(find.text('Pilih minimal satu hari main.'), findsOneWidget);
      expect(fake.calls('POST /api/groups/5/events'), isEmpty);
    },
  );

  testWidgets('cost rows need a whole positive amount', (tester) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter('/groups/5/events/new'));

    await tester.tap(find.text('Kam'));
    await tester.tap(find.text('+ Sewa lapangan'));
    await tester.pump();
    await _tapSave(tester);

    expect(
      find.text('Jumlah pos biaya 1 harus angka lebih dari Rp0.'),
      findsOneWidget,
    );
    expect(fake.calls('POST /api/groups/5/events'), isEmpty);
  });

  testWidgets('saves a recurring event with its days, time and cost template', (
    tester,
  ) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter('/groups/5/events/new'));

    await tester.enterText(
      find.widgetWithText(TextField, 'Nama event (opsional)'),
      'Futsal Kamis Malam',
    );
    await tester.tap(find.text('Kam'));
    await tester.tap(find.text('Sen'));
    await tester.tap(find.text('+ Sewa lapangan'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Jumlah'), '350000');
    await _tapSave(tester);

    expect(fake.calls('POST /api/groups/5/events').single.body, {
      'type': 'recurring',
      'name': 'Futsal Kamis Malam',
      'rrule': 'FREQ=WEEKLY;BYDAY=MO,TH',
      'time': '19:00',
      'cost_template': {
        'items': [
          {'category': 'Sewa lapangan', 'amount': 350000, 'scope': 'all'},
        ],
      },
    });
    expect(
      find.text('Event rutin dibuat. Sesi draft muncul 3 hari sebelum main.'),
      findsOneWidget,
    );
  });

  testWidgets('a one-off event needs a date, then is sent with a WIB timestamp', (
    tester,
  ) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter('/groups/5/events/new'));

    await tester.tap(find.text('Sekali jalan'));
    await tester.pump();
    expect(find.text('Hari main'), findsNothing);
    await _tapSave(tester);
    expect(find.text('Pilih tanggal acaranya.'), findsOneWidget);
    expect(fake.calls('POST /api/groups/5/events'), isEmpty);

    // The picker opens on tomorrow; OK takes it.
    await tester.tap(find.text('Pilih tanggal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _tapSave(tester);

    final tomorrow = DateUtils.dateOnly(
      DateTime.now(),
    ).add(const Duration(days: 1));
    final body = fake.calls('POST /api/groups/5/events').single.body;
    expect(body['type'], 'one_off');
    expect(
      body['starts_at'],
      '${tomorrow.year}-${_two(tomorrow.month)}-${_two(tomorrow.day)}T19:00:00+07:00',
    );
    expect(body.containsKey('rrule'), isFalse);
    expect(body['cost_template'], {'items': <Object>[]});
  });

  testWidgets('going back to the home after saving reloads it', (tester) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.screenRouter('/groups/5'));
    expect(fake.calls('GET /api/groups/5/home'), hasLength(1));

    await tester.tap(find.text('Buat event'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kam'));
    await _tapSave(tester);

    expect(find.text('Beranda'), findsOneWidget);
    expect(fake.calls('GET /api/groups/5/home'), hasLength(2));
  });
}
