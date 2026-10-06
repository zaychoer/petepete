import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_groups_api.dart';

FakeGroupsApi _group({String role = 'host'}) {
  final fake = FakeGroupsApi();
  fake.groups.add({
    'id': 5,
    'name': 'Futsal Kamis',
    'template': 'Futsal',
    'role': role,
  });
  fake.members[5] = [
    {'id': 1, 'display_name': 'Budi', 'role': 'host', 'has_account': true},
    {
      'id': 7,
      'display_name': 'Andi',
      'role': 'member',
      'has_account': false,
      'pending_claim': {'display_name': 'Andi Pratama'},
    },
    {'id': 8, 'display_name': 'Rudi', 'role': 'member', 'has_account': false},
  ];
  return fake;
}

void main() {
  group('claims', () {
    testWidgets('the host sees pending claims and approves one', (
      tester,
    ) async {
      final fake = _group();
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/members'));

      expect(find.text('Permintaan klaim nama'), findsOneWidget);
      expect(
        find.text('Andi Pratama ingin memakai nama "Andi"'),
        findsOneWidget,
      );

      await tester.tap(find.text('Setujui Andi'));
      await tester.pumpAndSettle();

      expect(fake.calls('POST /api/members/7/claim/approve'), hasLength(1));
      expect(find.text('Permintaan klaim nama'), findsNothing);
    });

    testWidgets('the host rejects a claim', (tester) async {
      final fake = _group();
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/members'));

      await tester.tap(find.text('Tolak Andi'));
      await tester.pumpAndSettle();

      expect(fake.calls('POST /api/members/7/claim/reject'), hasLength(1));
      expect(find.text('Permintaan klaim nama'), findsNothing);
      expect(find.text('Andi'), findsOneWidget, reason: 'still on the roster');
    });

    testWidgets('a member sees the roster but no host controls or claims', (
      tester,
    ) async {
      final fake = _group(role: 'member');
      // The API sends pending claims to hosts only.
      fake.members[5]![1].remove('pending_claim');
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/members'));

      expect(find.text('Rudi'), findsOneWidget);
      expect(find.text('Permintaan klaim nama'), findsNothing);
      expect(find.text('Undang'), findsNothing);
      expect(find.text('Tambah tamu'), findsNothing);
    });
  });

  group('add guest', () {
    Future<void> openDialog(WidgetTester tester) async {
      await tester.tap(find.text('Tambah tamu'));
      await tester.pumpAndSettle();
    }

    testWidgets('a name is enough; the guest then shows up on the roster', (
      tester,
    ) async {
      final fake = _group();
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/members'));

      await openDialog(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Nama tamu'),
        'Doni',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Tambah'));
      await tester.pumpAndSettle();

      expect(fake.calls('POST /api/groups/5/guests').single.body, {
        'name': 'Doni',
      });
      expect(find.text('Doni'), findsOneWidget);
      expect(find.text('Tamu'), findsOneWidget);
    });

    testWidgets('an optional WhatsApp number is sent normalised', (
      tester,
    ) async {
      final fake = _group();
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/members'));

      await openDialog(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Nama tamu'),
        'Doni',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Nomor WhatsApp (opsional)'),
        '0812-3456-7890',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Tambah'));
      await tester.pumpAndSettle();

      expect(fake.calls('POST /api/groups/5/guests').single.body, {
        'name': 'Doni',
        'phone': '6281234567890',
      });
    });

    testWidgets('a missing name or a bad number is refused before sending', (
      tester,
    ) async {
      final fake = _group();
      final app = AppHarness(fake);
      await app.pump(tester, app.screenRouter('/groups/5/members'));

      await openDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Tambah'));
      await tester.pumpAndSettle();
      expect(find.text('Nama tamu harus diisi.'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Nama tamu'),
        'Doni',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Nomor WhatsApp (opsional)'),
        '123',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Tambah'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nomor tidak valid'), findsOneWidget);
      expect(fake.calls('POST /api/groups/5/guests'), isEmpty);
    });
  });
}
