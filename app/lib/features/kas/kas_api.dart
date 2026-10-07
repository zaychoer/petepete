import '../../api/api_client.dart';
import 'kas_models.dart';

/// Typed calls for Kas & riwayat, corrections and Tarik dana. Every failure is an
/// `ApiError` whose `message` is ready to show.
///
/// Money POSTs take the `Idempotency-Key` from the caller: create it when the user
/// starts the action and pass the same key on every retry of that action.
class KasApi {
  const KasApi(this._api);

  final ApiClient _api;

  Future<KasGroup> group(int groupId) async =>
      KasGroup.fromJson(await _api.get('/api/groups/$groupId'));

  Future<KasBalances> balances(int groupId) async =>
      KasBalances.fromJson(await _api.get('/api/groups/$groupId/balances'));

  /// History, newest first; [memberId] limits it to txns that touch that member.
  Future<List<KasTxn>> txns(int groupId, {int? memberId}) async {
    final json = await _api.get(
      '/api/groups/$groupId/txns',
      query: memberId == null ? null : {'member_id': '$memberId'},
    );
    return [
      for (final t in json['txns'] as List<dynamic>) KasTxn.fromJson(t as Json),
    ];
  }

  /// "[payerId] bayar [amount] ke [payeeId]"; returns the new txn id.
  Future<int> recordSettlement(
    int groupId, {
    required int payerId,
    required int payeeId,
    required int amount,
    String? note,
    required String idempotencyKey,
  }) async {
    final json = await _api.post(
      '/api/groups/$groupId/settlements',
      idempotencyKey: idempotencyKey,
      body: {
        'from_member_id': payerId,
        'to_member_id': payeeId,
        'amount': amount,
        if (note != null) 'note': note,
      },
    );
    return json['txn_id'] as int;
  }

  /// [memberId] bought something for [amount] out of the kas; returns the txn id.
  Future<int> recordKasSpend(
    int groupId, {
    required int memberId,
    required int amount,
    String? note,
    required String idempotencyKey,
  }) async {
    final json = await _api.post(
      '/api/groups/$groupId/kas-spends',
      idempotencyKey: idempotencyKey,
      body: {
        'member_id': memberId,
        'amount': amount,
        if (note != null) 'note': note,
      },
    );
    return json['txn_id'] as int;
  }

  /// Undoes a settlement or kas spend; returns the correction's txn id.
  Future<int> correct(
    int txnId, {
    required String reason,
    required String idempotencyKey,
  }) async {
    final json = await _api.post(
      '/api/txns/$txnId/correction',
      idempotencyKey: idempotencyKey,
      body: {'reason': reason},
    );
    return json['txn_id'] as int;
  }

  Future<PayoutBalance> payoutBalance(int groupId) async =>
      PayoutBalance.fromJson(
        await _api.get('/api/groups/$groupId/payout-account/balance'),
      );

  Future<List<Withdrawal>> withdrawals(int groupId) async {
    final json = await _api.get('/api/groups/$groupId/withdrawals');
    return [
      for (final w in json['withdrawals'] as List<dynamic>)
        Withdrawal.fromJson(w as Json),
    ];
  }

  Future<WithdrawalResult> withdraw(
    int groupId, {
    required int amount,
    required String idempotencyKey,
  }) async => WithdrawalResult.fromJson(
    await _api.post(
      '/api/groups/$groupId/withdrawals',
      idempotencyKey: idempotencyKey,
      body: {'amount': amount},
    ),
  );
}
