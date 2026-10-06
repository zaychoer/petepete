import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/ui/rupiah.dart';

void main() {
  test('formats whole rupiah with dot separators and no decimals', () {
    expect(formatRupiah(0), 'Rp0');
    expect(formatRupiah(500), 'Rp500');
    expect(formatRupiah(1000), 'Rp1.000');
    expect(formatRupiah(45000), 'Rp45.000');
    expect(formatRupiah(123456), 'Rp123.456');
    expect(formatRupiah(1234567), 'Rp1.234.567');
    expect(formatRupiah(1000000000), 'Rp1.000.000.000');
  });

  test('puts the minus sign before Rp for negative amounts', () {
    expect(formatRupiah(-45000), '-Rp45.000');
    expect(formatRupiah(-1), '-Rp1');
  });
}
