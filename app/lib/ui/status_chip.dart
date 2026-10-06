import 'package:flutter/material.dart';

/// How a status looks. Colour is never the only signal: every tone has its own
/// icon and the chip always carries the label text.
enum StatusTone {
  success(Icons.check_circle_outline, Color(0xFFD7F0DC), Color(0xFF0B3D1A)),
  info(Icons.receipt_long_outlined, Color(0xFFDCE8FA), Color(0xFF12315E)),
  warning(Icons.schedule, Color(0xFFFFE8C2), Color(0xFF5A3600)),
  danger(Icons.report_problem_outlined, Color(0xFFFADADA), Color(0xFF6B1111)),
  neutral(Icons.remove_circle_outline, Color(0xFFE6E6E6), Color(0xFF2E2E2E));

  const StatusTone(this.icon, this.background, this.foreground);

  final IconData icon;
  final Color background;
  final Color foreground;
}

/// A small pill with an icon and a status word, e.g. "Lunas".
///
/// Use [StatusChip.bill] and [StatusChip.session] for the spec's labels; use the
/// plain constructor for anything else, always with a text [label].
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, required this.tone});

  /// Bill status from the API: `unpaid`, `paid`, `needs_review`, `void`.
  factory StatusChip.bill(String status, {Key? key}) {
    final (label, tone) = switch (status) {
      'unpaid' => ('Belum bayar', StatusTone.warning),
      'paid' => ('Lunas', StatusTone.success),
      'needs_review' => ('Perlu dicek', StatusTone.danger),
      'void' => ('Dibatalkan', StatusTone.neutral),
      _ => (status, StatusTone.neutral),
    };
    return StatusChip(key: key, label: label, tone: tone);
  }

  /// Session status from the API: `draft`, `issued`, `cancelled`. Pass
  /// [settled] for an issued session whose non-void bills are all paid
  /// ("Selesai" is derived, never stored).
  factory StatusChip.session(String status, {bool settled = false, Key? key}) {
    final (label, tone) = switch (status) {
      'draft' => ('Draft', StatusTone.neutral),
      'issued' when settled => ('Selesai', StatusTone.success),
      'issued' => ('Ditagih', StatusTone.info),
      'cancelled' => ('Batal', StatusTone.neutral),
      _ => (status, StatusTone.neutral),
    };
    return StatusChip(key: key, label: label, tone: tone);
  }

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: Icon(tone.icon, size: 16, color: tone.foreground),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: tone.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
