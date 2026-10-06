import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petepete/api/api_client.dart';
import 'package:petepete/api/api_error.dart';
import 'package:petepete/api/idempotency_key.dart';
import 'package:petepete/auth/token_store.dart';

import '../support/fake_api.dart';

void main() {
  const phone = '6281234567890';

  group('401 handling', () {
    late FakeApi fake;
    late ApiClient api;
    late MemoryTokenStore store;
    late int expired;

    setUp(() {
      fake = FakeApi();
      store = MemoryTokenStore(fake.signIn(phone));
      expired = 0;
      api = ApiClient(
        baseUrl: FakeApi.baseUrl,
        httpClient: fake.client,
        tokens: store,
        onSessionExpired: () => expired++,
      );
    });

    test(
      'refreshes once on a 401, stores the new tokens and retries',
      () async {
        final before = await store.read();
        fake.expireAccessTokens();

        final me = await api.get('/api/me');

        expect(me['display_name'], 'Budi');
        expect(fake.refreshCalls, 1);
        expect(fake.log, [
          'GET /api/me', // 401
          'POST /api/auth/refresh',
          'GET /api/me', // retried
        ]);
        final after = await store.read();
        expect(after!.accessToken, isNot(before!.accessToken));
        expect(after.refreshToken, isNot(before.refreshToken));
        expect(expired, 0);
      },
    );

    test('calls that fail together share one refresh', () async {
      fake.expireAccessTokens();

      final results = await Future.wait([
        api.get('/api/me'),
        api.get('/api/me'),
        api.get('/api/me'),
      ]);

      expect(results.map((r) => r['display_name']), everyElement('Budi'));
      expect(fake.refreshCalls, 1);
    });

    test('the retry of a money POST reuses its Idempotency-Key', () async {
      fake.expireAccessTokens();
      final key = newIdempotencyKey();

      await api.post(
        '/api/groups/g1/kas-spends',
        body: {'amount': 45000},
        idempotencyKey: key,
      );

      expect(fake.moneyKeys, [
        key,
      ]); // the 401'd attempt never reached the handler
      expect(fake.log.where((l) => l.contains('kas-spends')).length, 2);
    });

    test('a rejected refresh clears the session and reports it once', () async {
      fake.expireAccessTokens();
      fake.revokeRefreshTokens();

      await expectLater(
        api.get('/api/me'),
        throwsA(
          isA<ApiError>()
              .having((e) => e.isUnauthenticated, 'isUnauthenticated', isTrue)
              .having((e) => e.message, 'message', contains('Masuk lagi')),
        ),
      );

      expect(await store.read(), isNull);
      expect(expired, 1);
      expect(fake.refreshCalls, 1);
    });

    test('offline during refresh keeps the session', () async {
      fake.expireAccessTokens();
      fake.refreshOffline = true;

      await expectLater(
        api.get('/api/me'),
        throwsA(isA<ApiError>().having((e) => e.isNetwork, 'isNetwork', true)),
      );
      expect(await store.read(), isNotNull);
      expect(expired, 0);
    });

    test('unauthenticated calls never trigger a refresh', () async {
      await expectLater(
        api.post(
          '/api/auth/verify',
          body: {'phone': phone, 'code': '000000'},
          authenticated: false,
        ),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'invalid_code')),
      );
      expect(fake.refreshCalls, 0);
    });
  });

  group('errors', () {
    ApiClient clientAnswering(http.Response Function(http.Request) answer) =>
        ApiClient(
          baseUrl: 'http://api.test/',
          tokens: MemoryTokenStore(),
          httpClient: MockClient((request) async => answer(request)),
        );

    test('carry the server code with an Indonesian message', () async {
      final api = clientAnswering(
        (_) => http.Response('{"error":"rate_limited"}', 429),
      );

      await expectLater(
        api.post(
          '/api/auth/otp',
          body: {'phone': '6281234567890'},
          authenticated: false,
        ),
        throwsA(
          isA<ApiError>()
              .having((e) => e.statusCode, 'status', 429)
              .having((e) => e.code, 'code', 'rate_limited')
              .having((e) => e.isRateLimited, 'isRateLimited', isTrue)
              .having((e) => e.message, 'message', contains('terlalu sering')),
        ),
      );
    });

    test('prefer the server message and keep details', () async {
      final api = clientAnswering(
        (_) => http.Response(
          '{"error":"invalid_params","message":"Data belum lengkap.","details":{"amount":["wajib"]}}',
          422,
        ),
      );

      await expectLater(
        api.get('/api/x', authenticated: false),
        throwsA(
          isA<ApiError>()
              .having((e) => e.message, 'message', 'Data belum lengkap.')
              .having((e) => e.details, 'details', {
                'amount': ['wajib'],
              }),
        ),
      );
    });

    test('a non-JSON failure becomes server_error', () async {
      final api = clientAnswering(
        (_) => http.Response('<html>Bad Gateway</html>', 502),
      );

      await expectLater(
        api.get('/api/x', authenticated: false),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', 'server_error')),
      );
    });

    test('a timeout is a network error', () async {
      final api = ApiClient(
        baseUrl: 'http://api.test',
        tokens: MemoryTokenStore(),
        timeout: const Duration(milliseconds: 10),
        httpClient: MockClient((request) => Completer<http.Response>().future),
      );

      await expectLater(
        api.get('/api/x', authenticated: false),
        throwsA(
          isA<ApiError>().having((e) => e.isNetwork, 'isNetwork', isTrue),
        ),
      );
    });
  });

  group('newIdempotencyKey', () {
    test('is a v4 UUID and differs per call', () {
      final a = newIdempotencyKey();
      final b = newIdempotencyKey();

      expect(
        a,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(a, isNot(b));
    });
  });
}
