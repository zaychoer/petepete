import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/ui/date_format.dart';

void main() {
  test('formatWaktu writes day, Indonesian month, year and 24h time', () {
    expect(formatWaktu(DateTime(2026, 10, 6, 9, 5)), '6 Okt 2026, 09:05');
    expect(formatWaktu(DateTime(2027, 5, 21, 23, 59)), '21 Mei 2027, 23:59');
  });
}
