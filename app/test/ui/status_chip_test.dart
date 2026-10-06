import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/ui/status_chip.dart';

import '../support/sample.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget chip) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: chip)),
    ),
  );

  testWidgets('a bill chip shows the label the server sent, toned by status', (
    tester,
  ) async {
    final bills = Sample.load('share_bills.issued').json['bills'] as List;
    final tones = {
      'unpaid': StatusTone.warning,
      'paid': StatusTone.success,
      'needs_review': StatusTone.danger,
      'void': StatusTone.neutral,
    };
    for (final bill in bills.cast<Map<String, dynamic>>()) {
      final status = bill['status'] as String;
      final label = bill['status_label'] as String;
      await show(tester, StatusChip.bill(status, label: label));
      expect(find.text(label), findsOneWidget, reason: status);
      expect(find.byIcon(tones[status]!.icon), findsOneWidget, reason: status);
    }
  });

  testWidgets('a session chip shows the progress label, toned by progress', (
    tester,
  ) async {
    final tones = {
      'draft': ('session.draft', StatusTone.neutral),
      'issued': ('session.issued', StatusTone.info),
      'settled': ('session.settled', StatusTone.success),
    };
    for (final MapEntry(:key, :value) in tones.entries) {
      final session = Sample.load(value.$1).json['session'] as Map;
      expect(session['progress'], key);
      final label = session['progress_label'] as String;
      await show(tester, StatusChip.session(key, label: label));
      expect(find.text(label), findsOneWidget, reason: key);
      expect(find.byIcon(value.$2.icon), findsOneWidget, reason: key);
    }
  });

  testWidgets('an unknown status keeps the server label with a neutral tone', (
    tester,
  ) async {
    await show(tester, StatusChip.bill('refunded', label: 'Dikembalikan'));
    expect(find.text('Dikembalikan'), findsOneWidget);
    expect(find.byIcon(StatusTone.neutral.icon), findsOneWidget);
    await show(tester, StatusChip.session('archived', label: 'Arsip'));
    expect(find.text('Arsip'), findsOneWidget);
    expect(find.byIcon(StatusTone.neutral.icon), findsOneWidget);
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
