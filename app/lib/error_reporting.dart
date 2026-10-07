import 'dart:async';

import 'package:sentry_flutter/sentry_flutter.dart';

/// DSN comes from `--dart-define=SENTRY_DSN=...`. Empty (the default) disables Sentry.
const sentryDsn = String.fromEnvironment('SENTRY_DSN');

/// `--dart-define=SENTRY_ENVIRONMENT=staging|production`; defaults to the build mode.
const sentryEnvironment = String.fromEnvironment('SENTRY_ENVIRONMENT');

/// `--dart-define=SENTRY_TEST_EVENT=true` sends one test error at startup, to check
/// that events arrive with the `layer: app` tag and without phone numbers.
const sentryTestEvent = bool.fromEnvironment('SENTRY_TEST_EVENT');

const _phoneMask = '[PHONE]';

// Same rules as api/lib/petepete/phone_mask.ex and web/src/lib/sentry-scrub.ts.
final _phone = RegExp(
  r'(?<!\w)(?:\+|%2[Bb])?(?:62|0)[\s.\-]?[1-9](?:[\s.\-]?\d){7,12}(?!\d)',
);

/// Replaces every Indonesian phone number (08…, 62…, +62…) in [text].
String maskPhones(String text) => text.replaceAll(_phone, _phoneMask);

/// Returns a copy of [value] with every string, and every string map key, masked.
dynamic scrub(dynamic value) {
  if (value is String) return maskPhones(value);
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        maskPhones(entry.key.toString()): scrub(entry.value),
    };
  }
  if (value is List) return <dynamic>[for (final item in value) scrub(item)];
  return value;
}

/// Sentry `beforeSend`: tags the event with `layer: app` and masks phone numbers
/// in the whole payload (message, exception, breadcrumbs, request, user, extra).
SentryEvent? beforeSend(SentryEvent event, Hint hint) {
  final json = scrub(event.toJson()) as Map<String, dynamic>;
  json['tags'] = <String, dynamic>{
    ...?(json['tags'] as Map<String, dynamic>?),
    'layer': 'app',
  };
  return SentryEvent.fromJson(json);
}

/// Sentry `beforeBreadcrumb`: masks phone numbers in breadcrumbs.
Breadcrumb? beforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  if (breadcrumb == null) return null;
  return Breadcrumb.fromJson(
    scrub(breadcrumb.toJson()) as Map<String, dynamic>,
  );
}

void configureSentry(SentryFlutterOptions options) {
  options
    ..dsn = sentryDsn
    ..beforeSend = beforeSend
    ..beforeBreadcrumb = beforeBreadcrumb;
  if (sentryEnvironment.isNotEmpty) options.environment = sentryEnvironment;
}

/// Starts Sentry, then runs [app]. With no DSN the SDK stays off and [app] still runs.
Future<void> runWithErrorReporting(FutureOr<void> Function() app) {
  return SentryFlutter.init(
    configureSentry,
    appRunner: () async {
      await app();
      if (sentryTestEvent) {
        await Sentry.captureException(StateError('Sentry test event'));
      }
    },
  );
}
