import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/inline_error.dart';
import 'session_api.dart';
import 'session_models.dart';

/// What the host filled in for a cost item.
class CostDraft {
  const CostDraft({
    required this.category,
    required this.label,
    required this.amount,
    required this.paidBy,
    required this.subset,
    required this.members,
  });

  final String category;
  final String label;
  final int amount;
  final int paidBy;
  final bool subset;
  final List<int> members;
}

/// The cost entry sheet. For a new cost it takes a category chip, a nominal and
/// Simpan: the payer is the host and the cost is for everyone present unless the
/// host changes it. [onSave] throws on failure; the sheet then shows the message
/// and stays open so nothing typed is lost.
Future<void> showCostSheet(
  BuildContext context, {
  required GroupRoster roster,
  required String category,
  CostItem? existing,
  required Future<void> Function(CostDraft draft) onSave,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _CostSheet(
      roster: roster,
      category: category,
      existing: existing,
      onSave: onSave,
    ),
  );
}

class _CostSheet extends StatefulWidget {
  const _CostSheet({
    required this.roster,
    required this.category,
    required this.existing,
    required this.onSave,
  });

  final GroupRoster roster;
  final String category;
  final CostItem? existing;
  final Future<void> Function(CostDraft draft) onSave;

  @override
  State<_CostSheet> createState() => _CostSheetState();
}

class _CostSheetState extends State<_CostSheet> {
  late final _amount = TextEditingController(
    text: widget.existing == null ? '' : '${widget.existing!.amount}',
  );
  late final _label = TextEditingController(
    text: widget.existing?.label ?? widget.category,
  );
  late int _paidBy = widget.existing?.paidBy ?? widget.roster.youId;
  late bool _subset = widget.existing?.isSubset ?? false;
  late final Set<int> _members = {...?widget.existing?.members};
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = int.tryParse(_amount.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Nominal harus lebih dari Rp0.');
      return;
    }
    if (_subset && _members.isEmpty) {
      setState(() => _error = 'Pilih minimal satu peserta untuk pos ini.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        CostDraft(
          category: widget.existing?.category ?? widget.category,
          label: _label.text.trim().isEmpty
              ? widget.category
              : _label.text.trim(),
          amount: amount,
          paidBy: _paidBy,
          subset: _subset,
          members: _members.toList()..sort(),
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = widget.roster.members;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existing == null
                  ? 'Tambah biaya: ${widget.category}'
                  : 'Ubah biaya',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('cost-amount'),
              controller: _amount,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Nominal',
                prefixText: 'Rp',
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('cost-label'),
              controller: _label,
              decoration: const InputDecoration(labelText: 'Nama pos'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const Key('cost-payer'),
              initialValue: _paidBy,
              decoration: const InputDecoration(labelText: 'Dibayar oleh'),
              items: [
                for (final m in members)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text(
                      m.id == widget.roster.youId
                          ? '${m.displayName} (kamu)'
                          : m.displayName,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _paidBy = v ?? _paidBy),
            ),
            SwitchListTile(
              key: const Key('subset-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Hanya untuk…'),
              subtitle: const Text(
                'Pos ini cuma ditanggung peserta yang dicentang dan hadir.',
              ),
              value: _subset,
              onChanged: (v) => setState(() => _subset = v),
            ),
            if (_subset)
              for (final m in members)
                CheckboxListTile(
                  key: Key('subset-${m.id}'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(m.displayName),
                  value: _members.contains(m.id),
                  onChanged: (v) => setState(() {
                    if (v ?? false) {
                      _members.add(m.id);
                    } else {
                      _members.remove(m.id);
                    }
                  }),
                ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              InlineError(_error!),
            ],
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('cost-save'),
              onPressed: _saving ? null : _save,
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );
  }
}
