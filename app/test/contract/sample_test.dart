import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/sample.dart';

Matcher overrideError(String containing) => throwsA(
  isA<SampleOverrideError>().having(
    (e) => e.message,
    'message',
    contains(containing),
  ),
);

void main() {
  group('loading', () {
    test('loads the recorded pay page variants', () {
      final unpaid = Sample.load('pay_page.unpaid').json;
      expect(unpaid['status'], 'unpaid');
      expect(unpaid['status_label'], 'Belum bayar');
      expect(Sample.load('pay_page.paid').json['status_label'], 'Lunas');
      expect(Sample.load('pay_page.void').json['status_label'], 'Dibatalkan');
    });

    test('json is a fresh copy, mutating it leaves the sample alone', () {
      final sample = Sample.load('pay_page.unpaid');
      sample.json['status'] = 'paid';
      (sample.json['lines'] as List).clear();
      expect(sample.json['status'], 'unpaid');
      expect(sample.json['lines'], isNotEmpty);
    });

    test('encode gives the body as a JSON string', () {
      final sample = Sample.load('pay_page.unpaid');
      expect(jsonDecode(sample.encode()), sample.json);
    });

    test('an unknown sample names where it looked', () {
      expect(
        () => Sample.load('pay_page.nope'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('pay_page.nope'),
          ),
        ),
      );
    });

    test('is found from a subdirectory of the app', () {
      final dir = Sample.contractRoot();
      expect(File('${dir.path}/manifest.json').existsSync(), isTrue);
    });
  });

  group('error samples', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sample_test');
      Directory('${dir.path}/samples/errors').createSync(recursive: true);
      File(
        '${dir.path}/samples/errors/idempotency_key_required.json',
      ).writeAsStringSync(
        jsonEncode({
          'error': 'idempotency_key_required',
          'message': 'Kunci idempotensi wajib ada.',
        }),
      );
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('Sample.error reads samples/errors/<code>.json', () {
      final error = Sample.error('idempotency_key_required', contractDir: dir);
      expect(error.name, 'errors/idempotency_key_required');
      expect(error.json, {
        'error': 'idempotency_key_required',
        'message': 'Kunci idempotensi wajib ada.',
      });
    });

    test('error samples take overrides under the same rules', () {
      final error = Sample.error('idempotency_key_required', contractDir: dir);
      expect(error.patch({'message': 'Lain'}).json['message'], 'Lain');
      expect(() => error.patch({'message': 5}), overrideError('string to int'));
      expect(
        () => error.patch({'extra': 'x'}),
        overrideError('does not exist'),
      );
    });

    test('an unrecorded error code throws', () {
      expect(() => Sample.error('nope', contractDir: dir), throwsStateError);
    });
  });

  group('patch', () {
    final unpaid = Sample.load('pay_page.unpaid');

    test('replaces a scalar and leaves the rest and the original alone', () {
      final page = unpaid.patch({'amount_due': 50000, 'can_pay': false});
      expect(page.json['amount_due'], 50000);
      expect(page.json['can_pay'], false);
      expect(page.json['share'], unpaid.json['share']);
      expect(unpaid.json['amount_due'], 34000);
    });

    test('reaches into lists and maps with a dotted path', () {
      final page = unpaid.patch({
        'lines.0.amount': 1000,
        'methods.2.label': 'GoPay',
      });
      expect(((page.json['lines'] as List).first as Map)['amount'], 1000);
      expect(((page.json['methods'] as List)[2] as Map)['label'], 'GoPay');
    });

    test('merges a nested map into an object', () {
      final base = unpaid.patch({
        'attempt': {'status': 'pending'},
      });
      // attempt is null in the sample, so a whole object is accepted.
      expect(base.json['attempt'], {'status': 'pending'});
      final merged = base.patch({
        'attempt': {'status': 'paid'},
      });
      expect(merged.json['attempt'], {'status': 'paid'});
    });

    test('a nested map merge keeps sibling keys', () {
      final line = unpaid.patch({
        'lines': [
          {'amount': 1, 'category': 'a', 'label': 'b'},
        ],
      });
      final merged = line.patch({
        'lines.0': {'amount': 2},
      });
      expect(((merged.json['lines'] as List).first as Map), {
        'amount': 2,
        'category': 'a',
        'label': 'b',
      });
    });

    test('rejects a change of JSON type', () {
      expect(
        () => unpaid.patch({'amount_due': '34000'}),
        overrideError('amount_due changes type from int to string'),
      );
      expect(
        () => unpaid.patch({'can_pay': 'true'}),
        overrideError('can_pay changes type from bool to string'),
      );
      expect(
        () => unpaid.patch({'status': 1}),
        overrideError('status changes type from string to int'),
      );
      expect(
        () => unpaid.patch({'amount_due': 340.5}),
        overrideError('amount_due changes type from int to double'),
      );
      expect(
        () => unpaid.patch({'lines': 'none'}),
        overrideError('lines changes type from list to string'),
      );
      expect(
        () => unpaid.patch({
          'lines': {'amount': 1},
        }),
        overrideError('lines changes type from list to map'),
      );
      expect(
        () => unpaid.patch({'lines.0': 'x'}),
        overrideError('lines.0 changes type from map to string'),
      );
      expect(
        () => unpaid.patch({'lines.0.amount': '1'}),
        overrideError('lines.0.amount changes type from int to string'),
      );
    });

    test('null is free on both sides', () {
      final page = unpaid.patch({
        'attempt': 'abc',
        'message': 'Halo',
        'credit_applied': null,
      });
      expect(page.json['attempt'], 'abc');
      expect(page.json['message'], 'Halo');
      expect(page.json['credit_applied'], isNull);
    });

    test('rejects unknown keys and bad paths', () {
      expect(
        () => unpaid.patch({'amount': 1}),
        overrideError('amount does not exist'),
      );
      expect(
        () => unpaid.patch({'lines.3.amount': 1}),
        overrideError('lines.3 is not a valid index'),
      );
      expect(
        () => unpaid.patch({'lines.first.amount': 1}),
        overrideError('lines.first is not a valid index'),
      );
      expect(
        () => unpaid.patch({'lines.0.nope': 1}),
        overrideError('lines.0.nope does not exist'),
      );
      expect(
        () => unpaid.patch({
          'lines.0': {'nope': 1},
        }),
        overrideError('lines.0.nope does not exist'),
      );
      expect(
        () => unpaid.patch({'status.x': 1}),
        overrideError('override it as a whole'),
      );
    });

    test('rejects a list whose elements differ in shape from the first', () {
      expect(
        () => unpaid.patch({
          'lines': [
            {'amount': 'x', 'category': 'a', 'label': 'b'},
          ],
        }),
        overrideError('lines.0.amount changes type from int to string'),
      );
      expect(
        () => unpaid.patch({
          'lines': [
            {'amount': 1},
          ],
        }),
        overrideError('lines.0 changes the key set'),
      );
    });

    test('works on the paid and void variants', () {
      expect(
        Sample.load(
          'pay_page.paid',
        ).patch({'paid_at': '2026-10-06T04:00:00Z'}).json['paid_at'],
        '2026-10-06T04:00:00Z',
      );
      expect(
        () => Sample.load('pay_page.void').patch({'can_pay': 1}),
        overrideError('can_pay changes type from bool to int'),
      );
      // The void page records fewer keys than the unpaid one.
      expect(
        () => Sample.load('pay_page.void').patch({'amount_due': 1}),
        overrideError('amount_due does not exist'),
      );
    });
  });

  group('withItems', () {
    final unpaid = Sample.load('pay_page.unpaid');

    test('builds n elements from the first one with per-element overrides', () {
      final page = unpaid.withItems('lines', [
        {'label': 'Konsumsi', 'amount': 5000},
        {},
        {'category': 'air'},
      ]);
      final lines = (page.json['lines'] as List).cast<Map<String, dynamic>>();
      expect(lines.map((l) => l['label']), [
        'Konsumsi',
        'Sewa lapangan',
        'Sewa lapangan',
      ]);
      expect(lines.map((l) => l['amount']), [5000, 33333, 33333]);
      expect(lines.map((l) => l['category']), ['lapangan', 'lapangan', 'air']);
      expect((unpaid.json['lines'] as List), hasLength(1));
    });

    test('an empty list gives an empty array', () {
      expect(unpaid.withItems('methods', []).json['methods'], isEmpty);
    });

    test('rejects a type change inside an item', () {
      expect(
        () => unpaid.withItems('methods', [
          {'fee': '268'},
        ]),
        overrideError('methods.0.fee changes type from int to string'),
      );
    });

    test(
      'rejects a non-list path, an unknown key and an empty sample list',
      () {
        expect(
          () => unpaid.withItems('status', []),
          overrideError('needs a list'),
        );
        expect(
          () => unpaid.withItems('lines', [
            {'nope': 1},
          ]),
          overrideError('lines.0.nope does not exist'),
        );
        expect(
          () => Sample.load('pay_page.paid').withItems('methods', [{}]),
          overrideError('non-empty list'),
        );
      },
    );
  });
}
