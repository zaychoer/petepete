import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/auth/phone.dart';

void main() {
  test('normalises 08, +62 and 62 numbers like the API does', () {
    expect(normalizePhone('0812-3456-7890'), '6281234567890');
    expect(normalizePhone('+62 812 3456 7890'), '6281234567890');
    expect(normalizePhone('6281234567890'), '6281234567890');
    expect(normalizePhone('(0812) 3456.7890'), '6281234567890');
  });

  test('rejects numbers that are not Indonesian mobiles', () {
    expect(normalizePhone(''), isNull);
    expect(normalizePhone('12345'), isNull);
    expect(normalizePhone('0812345'), isNull); // too short
    expect(normalizePhone('0212345678'), isNull); // landline
    expect(normalizePhone('+1 415 555 0100'), isNull);
    expect(normalizePhone('08123456789012345'), isNull); // too long
  });

  test('shows the normalised number in groups', () {
    expect(formatPhoneForDisplay('6281234567890'), '+62 812-3456-7890');
    expect(formatPhoneForDisplay('628123456789'), '+62 812-3456-789');
  });
}
