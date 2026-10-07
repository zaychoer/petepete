import '../../api/api_client.dart';

int _int(Object? v) => (v as num).toInt();

/// A roster entry of the group (member or guest).
class RosterMember {
  const RosterMember({
    required this.id,
    required this.displayName,
    required this.role,
  });

  final int id;
  final String displayName;
  final String role;

  bool get isGuest => role == 'guest';

  factory RosterMember.fromJson(Json j) => RosterMember(
    id: _int(j['id']),
    displayName: j['display_name'] as String? ?? '',
    role: j['role'] as String? ?? 'member',
  );
}

/// The group data the session screens need: roster, who is looking, categories.
class GroupRoster {
  const GroupRoster({
    required this.members,
    required this.youId,
    required this.youRole,
    required this.categories,
  });

  final List<RosterMember> members;
  final int youId;

  /// The caller's role in the group: `host` or `member` (`you.role`).
  final String youRole;
  final List<String> categories;

  /// Only the host edits costs and attendance and sees bills and pay actions.
  bool get isHost => youRole == 'host';

  RosterMember? byId(int id) {
    for (final m in members) {
      if (m.id == id) return m;
    }
    return null;
  }

  String nameOf(int id) => byId(id)?.displayName ?? 'Mantan anggota';

  factory GroupRoster.fromJson(Json j) => GroupRoster(
    members: [
      for (final m in (j['members'] as List? ?? const []))
        RosterMember.fromJson(m as Json),
    ],
    youId: _int((j['you'] as Json)['member_id']),
    youRole: (j['you'] as Json)['role'] as String? ?? 'member',
    categories: [
      for (final c in (j['cost_categories'] as List? ?? const [])) c as String,
    ],
  );
}

class CostItem {
  const CostItem({
    required this.id,
    required this.category,
    required this.label,
    required this.amount,
    required this.paidBy,
    required this.paidByName,
    required this.scope,
    required this.members,
    required this.bearerIds,
  });

  final int id;
  final String category;
  final String label;
  final int amount;
  final int? paidBy;
  final String? paidByName;

  /// `all` or `subset`.
  final String scope;

  /// Selected members of a subset item.
  final List<int> members;

  /// Attending members who actually bear this item.
  final List<int> bearerIds;

  bool get isSubset => scope == 'subset';
  bool get hasNoBearer => bearerIds.isEmpty;

  factory CostItem.fromJson(Json j) => CostItem(
    id: _int(j['id']),
    category: j['category'] as String? ?? '',
    label: j['label'] as String? ?? '',
    amount: _int(j['amount']),
    paidBy: j['paid_by'] == null ? null : _int(j['paid_by']),
    paidByName: j['paid_by_name'] as String?,
    scope: j['scope'] as String? ?? 'all',
    members: [for (final m in (j['members'] as List? ?? const [])) _int(m)],
    bearerIds: [
      for (final m in (j['bearer_ids'] as List? ?? const [])) _int(m),
    ],
  );
}

class Participant {
  const Participant({
    required this.memberId,
    required this.displayName,
    required this.attended,
    required this.weight,
  });

  final int memberId;
  final String displayName;
  final bool attended;

  /// Integer per mil.
  final int weight;

  factory Participant.fromJson(Json j) => Participant(
    memberId: _int(j['member_id']),
    displayName: j['display_name'] as String? ?? '',
    attended: j['attended'] as bool? ?? false,
    weight: _int(j['weight']),
  );
}

class SessionDetail {
  const SessionDetail({
    required this.id,
    required this.groupId,
    required this.startsAt,
    required this.status,
    required this.progress,
    required this.statusLabel,
    required this.progressLabel,
    required this.costItems,
    required this.participants,
  });

  final int id;
  final int groupId;
  final String? startsAt;

  /// `draft`, `issued`, `cancelled`.
  final String status;

  /// `draft`, `issued`, `settled`, `cancelled` (derived by the server).
  final String progress;

  /// The server's text for [status] and [progress] ("Draft", "Ditagih", "Selesai").
  final String statusLabel;
  final String progressLabel;
  final List<CostItem> costItems;
  final List<Participant> participants;

  bool get isDraft => status == 'draft';

  int get totalCost => costItems.fold(0, (sum, i) => sum + i.amount);

  Participant? participant(int memberId) {
    for (final p in participants) {
      if (p.memberId == memberId) return p;
    }
    return null;
  }

  int get attendingCount => participants.where((p) => p.attended).length;

  /// Items nobody attending bears: they block sending the bill.
  List<CostItem> get itemsWithoutBearer =>
      costItems.where((i) => i.hasNoBearer).toList();

  factory SessionDetail.fromJson(Json j) {
    final s = j['session'] as Json;
    return SessionDetail(
      id: _int(s['id']),
      groupId: _int(s['group_id']),
      startsAt: s['starts_at'] as String?,
      status: s['status'] as String,
      progress: s['progress'] as String,
      statusLabel: s['status_label'] as String,
      progressLabel: s['progress_label'] as String,
      costItems: [
        for (final i in (j['cost_items'] as List? ?? const []))
          CostItem.fromJson(i as Json),
      ],
      participants: [
        for (final p in (j['participants'] as List? ?? const []))
          Participant.fromJson(p as Json),
      ],
    );
  }
}

/// A fraction of a rupiah, exact; [amount] is its nearest-rupiah display value.
class PreviewLine {
  const PreviewLine({
    required this.costItemId,
    required this.category,
    required this.label,
    required this.amount,
  });

  final int costItemId;
  final String category;
  final String label;
  final int amount;

  factory PreviewLine.fromJson(Json j) => PreviewLine(
    costItemId: _int(j['cost_item_id']),
    category: j['category'] as String? ?? '',
    label: j['label'] as String? ?? '',
    amount: _int(j['amount']),
  );
}

class PreviewMember {
  const PreviewMember({
    required this.memberId,
    required this.displayName,
    required this.weight,
    required this.lines,
    required this.share,
    required this.rounding,
    required this.creditApplied,
    required this.amountDue,
  });

  final int memberId;
  final String displayName;
  final int weight;
  final List<PreviewLine> lines;
  final int share;
  final int rounding;
  final int creditApplied;
  final int amountDue;

  factory PreviewMember.fromJson(Json j) => PreviewMember(
    memberId: _int(j['member_id']),
    displayName: j['display_name'] as String? ?? '',
    weight: _int(j['weight']),
    lines: [
      for (final l in (j['lines'] as List? ?? const []))
        PreviewLine.fromJson(l as Json),
    ],
    share: _int(j['share']),
    rounding: _int(j['rounding']),
    creditApplied: _int(j['credit_applied']),
    amountDue: _int(j['amount_due']),
  );
}

class PreviewItem {
  const PreviewItem({
    required this.id,
    required this.category,
    required this.label,
    required this.amount,
    required this.paidByMemberId,
  });

  final int id;
  final String category;
  final String label;
  final int amount;
  final int? paidByMemberId;

  factory PreviewItem.fromJson(Json j) => PreviewItem(
    id: _int(j['id']),
    category: j['category'] as String? ?? '',
    label: j['label'] as String? ?? '',
    amount: _int(j['amount']),
    paidByMemberId: j['paid_by_member_id'] == null
        ? null
        : _int(j['paid_by_member_id']),
  );
}

class Preview {
  const Preview({
    required this.totalCost,
    required this.totalBilled,
    required this.kasRemainder,
    required this.creditUsed,
    required this.totalDue,
    required this.items,
    required this.members,
  });

  final int totalCost;
  final int totalBilled;

  /// "Masuk kas".
  final int kasRemainder;
  final int creditUsed;
  final int totalDue;
  final List<PreviewItem> items;
  final List<PreviewMember> members;

  factory Preview.fromJson(Json j) => Preview(
    totalCost: _int(j['total_cost']),
    totalBilled: _int(j['total_billed']),
    kasRemainder: _int(j['kas_remainder']),
    creditUsed: _int(j['credit_used']),
    totalDue: _int(j['total_due']),
    items: [
      for (final i in (j['items'] as List? ?? const []))
        PreviewItem.fromJson(i as Json),
    ],
    members: [
      for (final m in (j['members'] as List? ?? const []))
        PreviewMember.fromJson(m as Json),
    ],
  );
}

/// One entry of the share endpoints: a bill with its ready-to-send text.
class ShareEntry {
  const ShareEntry({
    required this.billId,
    required this.displayName,
    required this.status,
    required this.statusLabel,
    required this.amountDue,
    required this.paidVia,
    required this.paidViaLabel,
    required this.paidAt,
    required this.cashCancellable,
    required this.hasPhone,
    required this.waNumber,
    required this.text,
    required this.shareUrl,
  });

  final int billId;
  final String displayName;

  /// `unpaid`, `paid`, `needs_review` or `void` (a bill of an earlier, voided issue).
  final String status;

  /// The server's text for [status].
  final String statusLabel;
  final int amountDue;

  /// How a paid bill was paid: `cash`, `gateway` or `credit`; null while unpaid.
  final String? paidVia;

  /// The server's text for [paidVia] ("Cash", "Online", "Saldo").
  final String? paidViaLabel;
  final String? paidAt;

  /// The server says the cash payment can still be undone (within 24 hours).
  final bool cashCancellable;
  final bool hasPhone;
  final String? waNumber;
  final String text;
  final String shareUrl;

  bool get isVoid => status == 'void';

  factory ShareEntry.fromJson(Json j) => ShareEntry(
    billId: _int(j['bill_id']),
    displayName: j['display_name'] as String? ?? '',
    status: j['status'] as String,
    statusLabel: j['status_label'] as String,
    amountDue: _int(j['amount_due']),
    paidVia: j['paid_via'] as String?,
    paidViaLabel: j['paid_via_label'] as String?,
    paidAt: j['paid_at'] as String?,
    cashCancellable: j['cash_cancellable'] == true,
    hasPhone: j['has_phone'] as bool? ?? false,
    waNumber: j['wa_number'] as String?,
    text: j['text'] as String? ?? '',
    shareUrl: j['share_url'] as String? ?? '',
  );
}

/// The reminder: a group text for everyone who still owes.
class Reminder {
  const Reminder({
    required this.count,
    required this.groupText,
    required this.shareUrl,
    required this.entries,
  });

  final int count;
  final String? groupText;
  final String? shareUrl;
  final List<ShareEntry> entries;

  factory Reminder.fromJson(Json j) => Reminder(
    count: _int(j['count']),
    groupText: j['group_text'] as String?,
    shareUrl: j['share_url'] as String?,
    entries: [
      for (final e in (j['bills'] as List? ?? const []))
        ShareEntry.fromJson(e as Json),
    ],
  );
}

class SummaryShare {
  const SummaryShare({required this.text, required this.shareUrl});

  final String text;
  final String shareUrl;

  factory SummaryShare.fromJson(Json j) => SummaryShare(
    text: j['text'] as String? ?? '',
    shareUrl: j['share_url'] as String? ?? '',
  );
}
