import 'dart:math';

final _secure = Random.secure();

/// A fresh random (v4 UUID) key for a money POST's `Idempotency-Key` header.
///
/// Generate it once when the user starts the action and reuse it for every retry of
/// that same action, so the API posts a single ledger txn. A new tap on a new
/// action gets a new key.
String newIdempotencyKey([Random? random]) {
  final r = random ?? _secure;
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
  return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
      '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
      '${hex.sublist(10).join()}';
}
