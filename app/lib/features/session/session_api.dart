import '../../api/api_client.dart';
import '../../api/api_error.dart';
import 'session_models.dart';

/// The session endpoints, typed. Money POSTs take the caller's idempotency key:
/// create it once per user action and reuse it when the same action is retried.
class SessionApi {
  SessionApi(this._api);

  final ApiClient _api;

  Future<GroupRoster> roster(int groupId) async =>
      GroupRoster.fromJson(await _api.get('/api/groups/$groupId'));

  Future<SessionDetail> session(int sessionId) async =>
      SessionDetail.fromJson(await _api.get('/api/sessions/$sessionId'));

  /// Creates ([costId] null) or replaces a cost item. Returns the saved item.
  Future<CostItem> saveCost(
    int sessionId, {
    int? costId,
    required String category,
    required String label,
    required int amount,
    required int paidBy,
    required bool subset,
    required List<int> members,
  }) async {
    final json =
        await _put('/api/sessions/$sessionId/costs/${costId ?? 'new'}', {
          'category': category,
          'label': label,
          'amount': amount,
          'paid_by': paidBy,
          'scope': subset ? 'subset' : 'all',
          if (subset) 'members': members,
        });
    return CostItem.fromJson(json['cost_item'] as Json);
  }

  Future<void> deleteCost(int sessionId, int costId) async {
    await _api.delete('/api/sessions/$sessionId/costs/$costId');
  }

  Future<Participant> setAttendance(
    int sessionId, {
    required int memberId,
    bool? attended,
    int? weight,
  }) async {
    final json = await _put('/api/sessions/$sessionId/attendance', {
      'member_id': memberId,
      'attended': ?attended,
      'weight': ?weight,
    });
    return Participant.fromJson(json['participant'] as Json);
  }

  /// Adds a guest to the group; returns the new member id.
  Future<int> addGuest(
    int groupId, {
    required String name,
    String? phone,
  }) async {
    final json = await _api.post(
      '/api/groups/$groupId/guests',
      body: {'name': name, 'phone': ?phone},
    );
    return (json['member_id'] as num).toInt();
  }

  Future<Preview> preview(int sessionId) async =>
      Preview.fromJson(await _api.get('/api/sessions/$sessionId/preview'));

  /// Issues the bills. Returns the response as is (bills with their pay tokens).
  Future<Json> issue(int sessionId, {required String idempotencyKey}) => _api
      .post('/api/sessions/$sessionId/issue', idempotencyKey: idempotencyKey);

  Future<void> void_(
    int sessionId, {
    required String reason,
    required String idempotencyKey,
  }) async {
    await _api.post(
      '/api/sessions/$sessionId/void',
      body: {'reason': reason},
      idempotencyKey: idempotencyKey,
    );
  }

  Future<List<ShareEntry>> shareBills(int sessionId) async {
    final json = await _api.get('/api/sessions/$sessionId/share/bills');
    return [
      for (final e in (json['bills'] as List? ?? const []))
        ShareEntry.fromJson(e as Json),
    ];
  }

  Future<Reminder> reminder(int sessionId) async => Reminder.fromJson(
    await _api.get('/api/sessions/$sessionId/share/reminder'),
  );

  Future<SummaryShare> summary(int sessionId) async => SummaryShare.fromJson(
    await _api.get('/api/sessions/$sessionId/share/summary'),
  );

  Future<void> markPaidCash(
    int billId, {
    required String idempotencyKey,
  }) async {
    await _api.post('/api/bills/$billId/cash', idempotencyKey: idempotencyKey);
  }

  Future<void> cancelCash(
    int billId, {
    required String reason,
    required String idempotencyKey,
  }) async {
    await _api.post(
      '/api/bills/$billId/cash/cancel',
      body: {'reason': reason},
      idempotencyKey: idempotencyKey,
    );
  }

  Future<Json> _put(String path, Object body) => _api.put(path, body: body);
}

/// Text safe to show for any failure of a session call.
String errorText(Object error) =>
    error is ApiError ? error.message : 'Ada yang salah. Coba lagi ya.';
