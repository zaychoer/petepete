import '../../api/api_client.dart';
import '../../api/api_error.dart';

int _int(Object? v) => (v as num).toInt();

/// A group in the caller's list (`GET /api/groups`).
class GroupSummary {
  const GroupSummary({
    required this.id,
    required this.name,
    required this.template,
    required this.role,
  });

  factory GroupSummary.fromJson(Json json) => GroupSummary(
    id: _int(json['id']),
    name: json['name'] as String,
    template: json['template'] as String?,
    role: json['role'] as String,
  );

  final int id;
  final String name;
  final String? template;
  final String role;
}

/// A roster entry: host, member or guest. Phone numbers are never read.
class RosterMember {
  const RosterMember({
    required this.id,
    required this.name,
    required this.role,
    required this.hasAccount,
    this.pendingClaimName,
  });

  factory RosterMember.fromJson(Json json) {
    final claim = json['pending_claim'];
    return RosterMember(
      id: _int(json['id']),
      name: json['display_name'] as String,
      role: json['role'] as String,
      hasAccount: json['has_account'] == true,
      pendingClaimName: claim is Map ? claim['display_name'] as String? : null,
    );
  }

  final int id;
  final String name;

  /// `host`, `member` or `guest`.
  final String role;
  final bool hasAccount;

  /// Name of the account asking to take over this entry, for the host to decide on.
  final String? pendingClaimName;

  bool get isGuest => role == 'guest';
}

/// `GET /api/groups/:id`.
class GroupDetail {
  const GroupDetail({
    required this.id,
    required this.name,
    required this.template,
    required this.costCategories,
    required this.members,
    required this.isHost,
    required this.memberId,
    this.inviteUrl,
  });

  factory GroupDetail.fromJson(Json json) => GroupDetail(
    id: _int(json['id']),
    name: json['name'] as String,
    template: json['template'] as String?,
    costCategories: [
      for (final c in json['cost_categories'] as List? ?? const []) c as String,
    ],
    members: [
      for (final m in json['members'] as List? ?? const [])
        RosterMember.fromJson(m as Json),
    ],
    isHost: (json['you'] as Json)['role'] == 'host',
    memberId: _int((json['you'] as Json)['member_id']),
    inviteUrl: json['invite_url'] as String?,
  );

  final int id;
  final String name;
  final String? template;
  final List<String> costCategories;
  final List<RosterMember> members;
  final bool isHost;

  /// The caller's own member id in this group (`you.member_id`).
  final int memberId;

  /// Only the host gets the invite link.
  final String? inviteUrl;
}

/// A bill row of the group home.
class OpenBill {
  const OpenBill({
    required this.id,
    required this.status,
    required this.amountDue,
    required this.memberName,
    required this.sessionId,
    required this.sessionStartsAt,
    required this.eventName,
  });

  factory OpenBill.fromJson(Json json) => OpenBill(
    id: _int(json['id']),
    status: json['status'] as String,
    amountDue: _int(json['amount_due']),
    memberName: json['member_name'] as String,
    sessionId: _int(json['session_id']),
    sessionStartsAt: json['session_starts_at'] as String,
    eventName: json['event_name'] as String,
  );

  final int id;
  final String status;
  final int amountDue;
  final String memberName;
  final int sessionId;
  final String sessionStartsAt;
  final String eventName;
}

/// The "sesi berikutnya" card.
class NextSession {
  const NextSession({
    required this.id,
    required this.eventName,
    required this.startsAt,
    required this.status,
    required this.progress,
    required this.costTotal,
    required this.attendedCount,
  });

  factory NextSession.fromJson(Json json) => NextSession(
    id: _int(json['id']),
    eventName: json['event_name'] as String,
    startsAt: json['starts_at'] as String,
    status: json['status'] as String,
    progress: json['progress'] as String,
    costTotal: _int(json['cost_total']),
    attendedCount: _int(json['attended_count']),
  );

  final int id;
  final String eventName;
  final String startsAt;
  final String status;

  /// `draft`, `issued`, `settled` or `cancelled`; `settled` is the derived "Selesai".
  final String progress;
  final int costTotal;
  final int attendedCount;
}

/// `GET /api/groups/:id/home`.
class GroupHome {
  const GroupHome({
    required this.groupName,
    required this.isHost,
    required this.nextSession,
    required this.kasBalance,
    required this.unpaid,
    required this.needsReview,
  });

  factory GroupHome.fromJson(Json json) {
    final next = json['next_session'];
    return GroupHome(
      groupName: (json['group'] as Json)['name'] as String,
      isHost: json['role'] == 'host',
      nextSession: next is Json ? NextSession.fromJson(next) : null,
      kasBalance: _int(json['kas_balance']),
      unpaid: [
        for (final b in json['unpaid_bills'] as List? ?? const [])
          OpenBill.fromJson(b as Json),
      ],
      needsReview: [
        for (final b in json['needs_review_bills'] as List? ?? const [])
          OpenBill.fromJson(b as Json),
      ],
    );
  }

  final String groupName;
  final bool isHost;
  final NextSession? nextSession;
  final int kasBalance;
  final List<OpenBill> unpaid;
  final List<OpenBill> needsReview;
}

/// What a join request answered.
class JoinResult {
  const JoinResult({required this.groupId, required this.groupName});

  final int groupId;
  final String groupName;
}

/// The host's payout account as `GET .../payout-account/balance` reports it.
class PayoutAccountInfo {
  const PayoutAccountInfo({
    required this.status,
    this.bankName,
    this.accountLast4,
  });

  factory PayoutAccountInfo.fromJson(Json json) => PayoutAccountInfo(
    status: json['status'] as String,
    bankName: json['bank_name'] as String?,
    accountLast4: json['account_last4'] as String?,
  );

  /// `pending_kyc` or `active`.
  final String status;
  final String? bankName;
  final String? accountLast4;
}

/// Calls for groups, roster, events and the payout account. Every failure is an
/// [ApiError]; screens show `error.message` (or [groupErrorMessage]).
class GroupsApi {
  const GroupsApi(this._api);

  final ApiClient _api;

  Future<List<GroupSummary>> listGroups() async {
    final json = await _api.get('/api/groups');
    return [
      for (final g in json['groups'] as List) GroupSummary.fromJson(g as Json),
    ];
  }

  /// Creates the group and returns its id; the caller becomes its host.
  Future<int> createGroup({
    required String name,
    required String template,
  }) async {
    final json = await _api.post(
      '/api/groups',
      body: {'name': name, 'template': template},
    );
    return _int(json['group_id']);
  }

  Future<GroupDetail> group(int id) async =>
      GroupDetail.fromJson(await _api.get('/api/groups/$id'));

  Future<GroupHome> home(int id) async =>
      GroupHome.fromJson(await _api.get('/api/groups/$id/home'));

  /// Replaces the invite token and returns the new link.
  Future<String> resetInvite(int groupId) async {
    final json = await _api.post('/api/groups/$groupId/invite/reset');
    return json['invite_url'] as String;
  }

  Future<void> addGuest(int groupId, {required String name, String? phone}) =>
      _api.post(
        '/api/groups/$groupId/guests',
        body: {'name': name, 'phone': ?phone},
      );

  Future<JoinResult> join(String token, {required String displayName}) async {
    final json = await _api.post(
      '/api/invites/$token/join',
      body: {'display_name': displayName},
    );
    final group = json['group'] as Json;
    return JoinResult(
      groupId: _int(group['id']),
      groupName: group['name'] as String,
    );
  }

  Future<void> claim(int memberId) => _api.post('/api/members/$memberId/claim');

  Future<void> approveClaim(int memberId) =>
      _api.post('/api/members/$memberId/claim/approve');

  Future<void> rejectClaim(int memberId) =>
      _api.post('/api/members/$memberId/claim/reject');

  Future<void> createEvent(int groupId, Json body) =>
      _api.post('/api/groups/$groupId/events', body: body);

  /// The registered payout account, or null when the group has none yet.
  Future<PayoutAccountInfo?> payoutAccount(int groupId) async {
    try {
      return PayoutAccountInfo.fromJson(
        await _api.get('/api/groups/$groupId/payout-account/balance'),
      );
    } on ApiError catch (e) {
      if (e.code == 'no_payout_account') return null;
      rethrow;
    }
  }

  /// Registers the host's bank account; answers the account's first status. Retries
  /// of the same registration pass the same [idempotencyKey].
  Future<String> registerPayoutAccount(
    int groupId, {
    required String idempotencyKey,
    required String bankName,
    required String accountNumber,
    required String accountHolderName,
  }) async {
    final json = await _api.post(
      '/api/groups/$groupId/payout-account',
      body: {
        'bank_name': bankName,
        'account_number': accountNumber,
        'account_holder_name': accountHolderName,
      },
      idempotencyKey: idempotencyKey,
    );
    return json['status'] as String;
  }

  /// Deletes the caller's account (`DELETE /api/me`).
  Future<void> deleteAccount() => _api.delete('/api/me');
}

const _groupMessages = <String, String>{
  'claim_pending':
      'Sudah ada yang mengajukan klaim untuk nama ini. Tunggu host memutuskan dulu.',
  'not_claimable': 'Nama ini sudah dipakai oleh akun lain.',
  'already_member': 'Kamu sudah jadi anggota grup ini.',
  'no_claim': 'Klaim ini sudah diputuskan. Muat ulang daftarnya.',
  'invalid_event': 'Data event belum benar. Cek lagi ya.',
  'no_payout_account': 'Grup belum punya rekening pencairan.',
};

/// Indonesian text for [error], with the group-specific codes the shell's table does
/// not know. `invalid` errors on a field explain themselves in [ApiError.details].
String groupErrorMessage(ApiError error) =>
    _groupMessages[error.code] ?? error.message;
