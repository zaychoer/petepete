import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/features/session/weight.dart';

void main() {
  test('weights show as 1×, 1,2×, 0,5× from per mil', () {
    expect(formatWeight(1000), '1×');
    expect(formatWeight(1200), '1,2×');
    expect(formatWeight(500), '0,5×');
    expect(formatWeight(1250), '1,25×');
    expect(formatWeight(2000), '2×');
  });

  test('typed weights become integer per mil, zero and junk are rejected', () {
    expect(parseWeight('1'), 1000);
    expect(parseWeight('1,2'), 1200);
    expect(parseWeight('1.2'), 1200);
    expect(parseWeight('0,5'), 500);
    expect(parseWeight(' 0,125 '), 125);
    expect(parseWeight('0'), isNull);
    expect(parseWeight('0,0'), isNull);
    expect(parseWeight('-1'), isNull);
    expect(parseWeight('abc'), isNull);
    expect(parseWeight(''), isNull);
    expect(parseWeight('1,2345'), isNull);
  });
}
