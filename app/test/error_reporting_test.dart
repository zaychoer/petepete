import 'package:flutter_test/flutter_test.dart';
import 'package:petepete/error_reporting.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('maskPhones', () {
    test('masks 08, 62 and +62 numbers, with separators', () {
      expect(
        maskPhones(
          'hubungi 081234567890 atau 6281234567890 atau +6281234567890 ya',
        ),
        'hubungi [PHONE] atau [PHONE] atau [PHONE] ya',
      );
      expect(maskPhones('+62 812-3456-7890'), '[PHONE]');
      expect(maskPhones('phone=%2B6281234567890&x=1'), 'phone=[PHONE]&x=1');
    });

    test('leaves amounts, dates, ids and short numbers alone', () {
      const text =
          'Rp45.000 total 150000 pada 2026-10-06 08:15:30 id 62 request F8a0812345678901Zx 0812';
      expect(maskPhones(text), text);
      expect(maskPhones('08123456789012345678'), '08123456789012345678');
    });
  });

  group('beforeSend', () {
    test(
      'tags the event with layer app and masks phone numbers everywhere',
      () {
        final event = SentryEvent(
          message: SentryMessage('OTP gagal untuk 081234567890'),
          exceptions: [
            SentryException(
              type: 'StateError',
              value: 'kirim ke +6281234567890',
            ),
          ],
          breadcrumbs: [
            Breadcrumb(
              message: 'klik 081234567890',
              data: {'to': '6281234567890'},
            ),
          ],
          request: SentryRequest(
            url: 'https://x.test/bayar?phone=6281234567890',
          ),
          tags: {'foo': 'bar'},
        );

        final sent = beforeSend(event, Hint())!;
        final json = sent.toJson().toString();

        expect(json, isNot(contains('1234567890')));
        expect(json, contains('[PHONE]'));
        expect(sent.tags, {'foo': 'bar', 'layer': 'app'});
      },
    );

    test('masks breadcrumbs', () {
      final crumb = beforeBreadcrumb(
        Breadcrumb(message: 'ke 081234567890'),
        Hint(),
      );
      expect(crumb!.message, 'ke [PHONE]');
    });
  });
}
