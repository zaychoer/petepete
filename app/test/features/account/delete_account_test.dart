import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_groups_api.dart';

FakeGroupsApi _fake() {
  final fake = FakeGroupsApi();
  fake.groups.addAll([
    {'id': 5, 'name': 'Futsal Kamis', 'template': 'Futsal', 'role': 'host'},
    {'id': 6, 'name': 'Padel Minggu', 'template': 'Padel', 'role': 'member'},
  ]);
  return fake;
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.text('Hapus akun saya'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Ya, hapus akunku'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('nothing is deleted until the user confirms', (tester) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.appRouter);
    app.appRouter.go('/akun/hapus');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hapus akun saya'));
    await tester.pumpAndSettle();
    expect(find.text('Hapus akun?'), findsOneWidget);
    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();

    expect(fake.calls('DELETE /api/me'), isEmpty);
    expect(find.text('Hapus akun saya'), findsOneWidget);
  });

  testWidgets('an active host is told why and stays signed in', (tester) async {
    final fake = _fake()..deleteAccountError = 'still_host';
    final app = AppHarness(fake);
    await app.pump(tester, app.appRouter);
    app.appRouter.go('/akun/hapus');
    await tester.pumpAndSettle();

    await _confirm(tester);

    expect(fake.calls('DELETE /api/me'), hasLength(1));
    expect(
      find.text(
        'Kamu masih jadi host grup aktif. Serahkan atau tutup grupnya dulu.',
      ),
      findsOneWidget,
    );
    expect(find.text('Hapus akun saya'), findsOneWidget);
    expect(find.text('Masuk ke Petepete'), findsNothing);
  });

  testWidgets('a deleted account is logged out to the login screen', (
    tester,
  ) async {
    final fake = _fake();
    final app = AppHarness(fake);
    await app.pump(tester, app.appRouter);
    app.appRouter.go('/akun/hapus');
    await tester.pumpAndSettle();

    await _confirm(tester);

    expect(find.text('Masuk ke Petepete'), findsOneWidget);
  });
}
