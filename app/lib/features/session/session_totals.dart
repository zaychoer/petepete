import 'package:flutter/material.dart';

import '../../ui/rupiah.dart';
import 'session_models.dart';

/// "Total biaya" and the rough per-person figure of a draft session, with the note
/// that the exact amounts come later. Shown to the host and, read-only,
/// to members.
class SessionTotals extends StatelessWidget {
  const SessionTotals({super.key, required this.detail, required this.note});

  final SessionDetail detail;

  /// The line under the card about where the exact amounts come from.
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final attending = detail.attendingCount;
    final total = detail.totalCost;
    final perPerson = attending > 0 && total > 0
        ? '≈ ${formatRupiah((total + attending - 1) ~/ attending)}'
        : '—';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Total biaya'),
                      Text(
                        formatRupiah(total),
                        key: const Key('header-total'),
                        style: theme.textTheme.headlineSmall,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Per orang ($attending hadir)'),
                      Text(
                        perPerson,
                        key: const Key('header-per-person'),
                        style: theme.textTheme.headlineSmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text(note, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }
}
