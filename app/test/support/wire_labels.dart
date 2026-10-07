import 'sample.dart';

/// Status text the server sends next to a status code (`status_label`,
/// `role_label`, `paid_via_label`, `progress_label`, `kind_label`), read from
/// the recorded samples so fakes never type Indonesian status text themselves
/// (ADR-0004).
///
/// Every lookup throws when no recorded sample carries a label for the code:
/// record one on the server first.
class WireLabels {
  WireLabels._();

  /// `host` -> "Host", `member` -> "Anggota", `guest` -> "Tamu".
  static String role(String code) => _find(_roles, code, 'role');

  /// `unpaid | paid | needs_review | void`.
  static String bill(String code) => _find(_bills, code, 'bill status');

  /// `cash | gateway | credit`.
  static String paidVia(String code) => _find(_paidVia, code, 'paid_via');

  /// A session's `status` or `progress`: `draft | issued | settled | cancelled`.
  static String session(String code) => _find(_sessions, code, 'session');

  /// A ledger txn `kind` (`settlement`, `kas_spend`, ...) from `txns.history`.
  static String txnKind(String code) => _find(_txnKinds, code, 'txn kind');

  /// `pending | submitted | managed | failed | needs_review`.
  static String withdrawal(String code) =>
      _find(_withdrawals, code, 'withdrawal status');

  /// `pending_kyc | active | registering | failed`.
  static String payoutAccount(String code) =>
      _find(_payoutAccounts, code, 'payout account status');

  static String _find(Map<String, String> table, String code, String what) {
    final label = table[code];
    if (label == null) {
      throw StateError(
        'No recorded sample carries a label for $what "$code" '
        '(known: ${table.keys.join(', ')})',
      );
    }
    return label;
  }

  static final _roles = _pairs([
    (Sample.load('group_detail.host').json['members'], 'role', 'role_label'),
    (Sample.load('session.draft').json['participants'], 'role', 'role_label'),
  ]);

  static final _bills = _pairs([
    (Sample.load('share_bills.issued').json['bills'], 'status', 'status_label'),
  ]);

  static final _paidVia = _pairs([
    (
      Sample.load('share_bills.issued').json['bills'],
      'paid_via',
      'paid_via_label',
    ),
  ]);

  static final _sessions = () {
    final table = <String, String>{};
    for (final name in [
      'session.draft',
      'session.issued',
      'session.settled',
      'session.cancelled',
    ]) {
      final session = Sample.load(name).json['session'] as Map<String, dynamic>;
      table[session['progress'] as String] =
          session['progress_label'] as String;
    }
    return table;
  }();

  static final _txnKinds = _pairs([
    (Sample.load('txns.history').json['txns'], 'kind', 'kind_label'),
  ]);

  static final _withdrawals = _pairs([
    (
      Sample.load('withdrawals.history').json['withdrawals'],
      'status',
      'status_label',
    ),
  ]);

  static final _payoutAccounts = _pairs([
    (Sample.load('payout_balance.active').json, 'status', 'status_label'),
    (Sample.load('payout_account.pending_kyc').json, 'status', 'status_label'),
    (Sample.load('payout_account.registering').json, 'status', 'status_label'),
    (Sample.load('payout_account.failed').json, 'status', 'status_label'),
  ]);

  /// Collects `code -> label` pairs from objects (or lists of objects).
  static Map<String, String> _pairs(List<(Object?, String, String)> sources) {
    final table = <String, String>{};
    for (final (source, codeKey, labelKey) in sources) {
      final rows = source is List ? source : [source];
      for (final row in rows.cast<Map<String, dynamic>>()) {
        final code = row[codeKey];
        final label = row[labelKey];
        if (code is String && label is String) table[code] = label;
      }
    }
    return table;
  }
}
