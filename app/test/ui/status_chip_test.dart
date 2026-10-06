import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/ui/status_chip.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget chip) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: chip)),
    ),
  );

  testWidgets('bill statuses show their Indonesian label', (tester) async {
    const labels = {
      'unpaid': 'Belum bayar',
      'paid': 'Lunas',
      'needs_review': 'Perlu dicek',
      'void': 'Dibatalkan',
    };
    for (final MapEntry(:key, :value) in labels.entries) {
      await show(tester, StatusChip.bill(key));
      expect(find.text(value), findsOneWidget, reason: key);
    }
  });

  testWidgets('session statuses show their label; Selesai is derived', (
    tester,
  ) async {
    await show(tester, StatusChip.session('draft'));
    expect(find.text('Draft'), findsOneWidget);
    await show(tester, StatusChip.session('issued'));
    expect(find.text('Ditagih'), findsOneWidget);
    await show(tester, StatusChip.session('issued', settled: true));
    expect(find.text('Selesai'), findsOneWidget);
    await show(tester, StatusChip.session('cancelled'));
    expect(find.text('Batal'), findsOneWidget);
  });

  testWidgets('every tone carries an icon of its own next to the text', (
    tester,
  ) async {
    final icons = StatusTone.values.map((t) => t.icon).toSet();
    expect(icons.length, StatusTone.values.length);

    await show(
      tester,
      const StatusChip(label: 'Lunas', tone: StatusTone.success),
    );
    expect(find.byIcon(StatusTone.success.icon), findsOneWidget);
    expect(find.text('Lunas'), findsOneWidget);
  });
}
