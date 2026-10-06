import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_groups_api.dart';

void main() {
  testWidgets(
    'a new host gets from the landing to the group home in 3 screens, with the template defaults visible',
    (tester) async {
      final fake = FakeGroupsApi();
      final app = AppHarness(fake);
      final router = app.appRouter;
      final screens = <String>[];
      void record() {
        final path =
            router.routerDelegate.currentConfiguration.last.matchedLocation;
        if (screens.isEmpty || screens.last != path) screens.add(path);
      }

      router.routerDelegate.addListener(record);
      await app.pump(tester, router);
      record();

      // Screen 1: nama grup.
      expect(find.widgetWithText(TextField, 'Nama grup'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Lanjut'))
            .onPressed,
        isNull,
        reason: 'a name is required',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Nama grup'),
        '  Badminton Jumat  ',
      );
      await tester.pump();
      await tester.tap(find.text('Lanjut'));
      await tester.pumpAndSettle();

      // Screen 2: template, with each template's default cost items on show.
      for (final name in [
        'Futsal',
        'Badminton',
        'Padel',
        'Mini Soccer',
        'Acara Umum',
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.text('Shuttlecock'), findsOneWidget); // Badminton only
      expect(find.text('Rompi'), findsOneWidget); // Mini Soccer only
      expect(find.text('Konsumsi'), findsOneWidget); // Acara Umum only
      expect(find.text('Pembulatan patungan: Rp1.000'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Buat grup'),
            )
            .onPressed,
        isNull,
        reason: 'a template must be picked',
      );

      await tester.tap(find.text('Badminton'));
      await tester.pump();
      await tester.tap(find.text('Buat grup'));
      await tester.pumpAndSettle();

      // Screen 3: the group home.
      expect(find.text('Beranda'), findsOneWidget);
      expect(find.text('Badminton Jumat'), findsOneWidget);
      final created = fake.calls('POST /api/groups').single.body;
      expect(created, {'name': 'Badminton Jumat', 'template': 'Badminton'});

      expect(screens, hasLength(3), reason: screens.join(' -> '));
      router.routerDelegate.removeListener(record);
    },
  );

  testWidgets('someone with one group lands straight on its home', (
    tester,
  ) async {
    final fake = FakeGroupsApi();
    fake.groups.add({
      'id': 5,
      'name': 'Futsal Kamis',
      'template': 'Futsal',
      'role': 'host',
    });
    fake.homes[5] = emptyHome(5, 'Futsal Kamis');
    final app = AppHarness(fake);

    await app.pump(tester, app.appRouter);

    expect(find.text('Beranda'), findsOneWidget);
    expect(find.text('Futsal Kamis'), findsOneWidget);
    expect(find.text('Nama grup'), findsNothing);
  });

  testWidgets('someone with several groups picks one from the list', (
    tester,
  ) async {
    final fake = FakeGroupsApi();
    fake.groups.addAll([
      {'id': 5, 'name': 'Futsal Kamis', 'template': 'Futsal', 'role': 'host'},
      {'id': 6, 'name': 'Padel Minggu', 'template': 'Padel', 'role': 'member'},
    ]);
    fake.homes[6] = emptyHome(6, 'Padel Minggu', role: 'member');
    final app = AppHarness(fake);

    await app.pump(tester, app.appRouter);
    expect(find.text('Grupku'), findsOneWidget);
    expect(find.text('Futsal Kamis'), findsOneWidget);

    await tester.tap(find.text('Padel Minggu'));
    await tester.pumpAndSettle();

    expect(find.text('Beranda'), findsOneWidget);
    expect(fake.calls('GET /api/groups/6/home'), hasLength(1));
  });
}
