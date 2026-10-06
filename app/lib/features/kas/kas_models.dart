import '../../api/api_client.dart';

/// One line of a ledger txn: who (or the kas) moved by how much (signed rupiah).
class KasEntry {
  const KasEntry({
    required this.accountType,
    required this.memberId,
    required this.displayName,
    required this.amount,
  });

  factory KasEntry.fromJson(Json json) => KasEntry(
    accountType: json['account_type'] as String,
    memberId: json['member_id'] as int?,
    displayName: json['display_name'] as String?,
    amount: json['amount'] as int,
  );

  /// `member` or `kas`.
  final String accountType;
  final int? memberId;
  final String? displayName;
  final int amount;
}

/// One ledger txn as the history shows it. [description] is the server's casual
/// Indonesian sentence ("Andi bayar Rp45.000"); show it as is.
class KasTxn {
  const KasTxn({
    required this.id,
    required this.kind,
    required this.kindLabel,
    required this.description,
    required this.reason,
    required this.reversesTxnId,
    required this.insertedAt,
    required this.entries,
  });

  factory KasTxn.fromJson(Json json) => KasTxn(
    id: json['id'] as int,
    kind: json['kind'] as String,
    kindLabel: json['kind_label'] as String,
    description: json['description'] as String,
    reason: json['reason'] as String?,
    reversesTxnId: json['reverses_txn_id'] as int?,
    insertedAt: DateTime.parse(json['inserted_at'] as String),
    entries: [
      for (final e in json['entries'] as List<dynamic>)
        KasEntry.fromJson(e as Json),
    ],
  );

  final int id;

  /// One of the eight ledger kinds, e.g. `settlement`, `kas_spend`, `correction`.
  final String kind;

  /// The server's text for [kind] ("Pelunasan"); show it as is.
  final String kindLabel;
  final String description;
  final String? reason;

  /// For a `correction`: the txn it undoes.
  final int? reversesTxnId;
  final DateTime insertedAt;
  final List<KasEntry> entries;

  /// The host can undo only these two kinds; the Ledger rejects the rest.
  bool get isCorrectable => kind == 'settlement' || kind == 'kas_spend';
}

class MemberBalance {
  const MemberBalance({
    required this.memberId,
    required this.displayName,
    required this.balance,
  });

  factory MemberBalance.fromJson(Json json) => MemberBalance(
    memberId: json['member_id'] as int,
    displayName: (json['display_name'] as String?) ?? 'Mantan anggota',
    balance: json['balance'] as int,
  );

  final int memberId;
  final String displayName;

  /// Negative: owes the group. Positive: has credit.
  final int balance;
}

/// `GET /api/groups/:id/balances`.
class KasBalances {
  const KasBalances({required this.kas, required this.members});

  factory KasBalances.fromJson(Json json) => KasBalances(
    kas: json['kas'] as int,
    members: [
      for (final m in json['members'] as List<dynamic>)
        MemberBalance.fromJson(m as Json),
    ],
  );

  final int kas;
  final List<MemberBalance> members;
}

/// A roster entry, enough to pick who paid whom.
class RosterMember {
  const RosterMember({required this.id, required this.displayName});

  final int id;
  final String displayName;
}

/// The group's roster and who is looking, from `GET /api/groups/:id`.
class KasGroup {
  const KasGroup({
    required this.members,
    required this.meId,
    required this.isHost,
  });

  factory KasGroup.fromJson(Json json) {
    final you = json['you'] as Json;
    return KasGroup(
      members: [
        for (final m in json['members'] as List<dynamic>)
          RosterMember(
            id: (m as Json)['id'] as int,
            displayName: m['display_name'] as String,
          ),
      ],
      meId: you['member_id'] as int,
      isHost: you['role'] == 'host',
    );
  }

  final List<RosterMember> members;
  final int meId;
  final bool isHost;
}

/// `GET /api/groups/:id/payout-account/balance`.
class PayoutBalance {
  const PayoutBalance({
    required this.balance,
    required this.status,
    required this.bankName,
    required this.accountLast4,
    required this.owner,
    required this.canWithdraw,
  });

  factory PayoutBalance.fromJson(Json json) => PayoutBalance(
    balance: json['balance'] as int,
    status: json['status'] as String,
    bankName: json['bank_name'] as String?,
    accountLast4: json['account_last4'] as String?,
    owner: json['owner'] as bool,
    canWithdraw: json['can_withdraw'] as bool,
  );

  /// Rupiah in the gateway sub-account.
  final int balance;

  /// Payout account status; only `active` can withdraw.
  final String status;
  final String? bankName;
  final String? accountLast4;

  /// The caller owns the registered account.
  final bool owner;
  final bool canWithdraw;
}

class Withdrawal {
  const Withdrawal({
    required this.id,
    required this.amount,
    required this.status,
    required this.statusLabel,
    required this.managedUrl,
    required this.insertedAt,
  });

  factory Withdrawal.fromJson(Json json) => Withdrawal(
    id: json['id'] as int,
    amount: json['amount'] as int,
    status: json['status'] as String,
    statusLabel: json['status_label'] as String,
    managedUrl: json['managed_url'] as String?,
    insertedAt: DateTime.parse(json['inserted_at'] as String),
  );

  final int id;
  final int amount;

  /// `pending`, `submitted`, `managed` or `failed`.
  final String status;
  final String statusLabel;

  /// Gateway dashboard link when the sub-account is managed.
  final String? managedUrl;
  final DateTime insertedAt;
}

/// Result of `POST /api/groups/:id/withdrawals`.
class WithdrawalResult {
  const WithdrawalResult({
    required this.withdrawalId,
    required this.status,
    required this.statusLabel,
    required this.managedUrl,
  });

  factory WithdrawalResult.fromJson(Json json) => WithdrawalResult(
    withdrawalId: json['withdrawal_id'] as int,
    status: json['status'] as String,
    statusLabel: json['status_label'] as String,
    managedUrl: json['managed_url'] as String?,
  );

  final int withdrawalId;
  final String status;
  final String statusLabel;
  final String? managedUrl;
}
