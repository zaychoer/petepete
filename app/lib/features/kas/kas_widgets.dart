import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/idempotency_key.dart';
import '../../ui/status_chip.dart';
import 'kas_models.dart';

/// The `Idempotency-Key` of one money action on a screen.
///
/// [current] creates the key the first time the action starts and returns the same
/// one on every retry; call [reset] when the action succeeded or the user changed
/// what is being sent (a new key for a different request).
class AttemptKey {
  String? _key;

  String get current => _key ??= newIdempotencyKey();

  void reset() => _key = null;
}

/// Whole rupiah from what the user typed, or null when it is empty or not a number.
int? parseAmount(String text) => int.tryParse(text.trim());

/// Why [amount] cannot be posted, or null when it is fine. Integer rupiah > 0.
String? amountError(int? amount) {
  if (amount == null || amount <= 0) return 'Nominal harus lebih dari Rp0.';
  return null;
}

/// A rupiah input: digits only, no decimals.
class AmountField extends StatelessWidget {
  const AmountField({
    super.key,
    required this.controller,
    this.label = 'Nominal (Rp)',
    this.errorText,
    this.onChanged,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(12),
      ],
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        prefixText: 'Rp',
        errorText: errorText,
      ),
    );
  }
}

/// A failed load: the message and a retry button.
class LoadErrorView extends StatelessWidget {
  const LoadErrorView({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Coba lagi')),
          ],
        ),
      ),
    );
  }
}

/// The chip of a ledger kind: the server's [label] (`kind_label`) with a tone
/// picked here; a kind the app does not know gets the neutral tone.
StatusChip kindChip(String kind, {required String label}) {
  final tone = switch (kind) {
    'session_billed' || 'settlement' || 'kas_spend' => StatusTone.info,
    'gateway_payment_received' || 'cash_received' => StatusTone.success,
    'correction' => StatusTone.warning,
    _ => StatusTone.neutral,
  };
  return StatusChip(label: label, tone: tone);
}

/// A dropdown of group members. [meId] reads as "Saya (name)".
class MemberDropdown extends StatelessWidget {
  const MemberDropdown({
    super.key,
    required this.label,
    required this.members,
    required this.meId,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final List<RosterMember> members;
  final int meId;
  final int? value;
  final ValueChanged<int?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      isExpanded: true,
      items: [
        for (final m in members)
          DropdownMenuItem(
            value: m.id,
            child: Text(
              m.id == meId ? 'Saya (${m.displayName})' : m.displayName,
            ),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}
