import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/ui/rupiah.dart';

import '../support/sample.dart';

void main() {
  final cases = (Sample.readContractFile('rupiah.json') as List)
      .cast<Map<String, dynamic>>();

  test('contract/rupiah.json has cases', () {
    expect(cases, isNotEmpty);
  });

  for (final c in cases) {
    test('formatRupiah(${c['amount']}) is ${c['text']}', () {
      expect(formatRupiah(c['amount'] as int), c['text']);
    });
  }
}
