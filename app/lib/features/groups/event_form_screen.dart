import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import 'async_body.dart';
import 'group_paths.dart';
import 'groups_api.dart';
import 'wib.dart';

/// Weekdays in RRULE order (Monday first) with the short names shown on the chips.
const _weekdays = [
  ('MO', 'Sen'),
  ('TU', 'Sel'),
  ('WE', 'Rab'),
  ('TH', 'Kam'),
  ('FR', 'Jum'),
  ('SA', 'Sab'),
  ('SU', 'Min'),
];

enum _Kind { recurring, oneOff }

class _CostRow {
  _CostRow(String category)
    : category = TextEditingController(text: category),
      amount = TextEditingController();

  final TextEditingController category;
  final TextEditingController amount;

  void dispose() {
    category.dispose();
    amount.dispose();
  }
}

/// Creates an event on one screen: a regular one (weekdays + time) or a one-off (a
/// date + time), with the default cost items every session starts with.
class EventFormScreen extends StatelessWidget {
  const EventFormScreen({super.key, required this.groupId});

  final int groupId;

  @override
  Widget build(BuildContext context) {
    final api = GroupsApi(AppScope.of(context).api);
    return Scaffold(
      appBar: AppBar(title: const Text('Buat event')),
      body: AsyncBody<GroupDetail>(
        load: () => api.group(groupId),
        builder: (context, group, _) => _EventForm(
          api: api,
          groupId: groupId,
          categories: group.costCategories,
          hostMemberId: group.memberId,
        ),
      ),
    );
  }
}

class _EventForm extends StatefulWidget {
  const _EventForm({
    required this.api,
    required this.groupId,
    required this.categories,
    required this.hostMemberId,
  });

  final GroupsApi api;
  final int groupId;
  final List<String> categories;

  /// The creating host's member id: the payer of every template item.
  final int hostMemberId;

  @override
  State<_EventForm> createState() => _EventFormState();
}

class _EventFormState extends State<_EventForm> {
  final _name = TextEditingController();
  final _days = <String>{};
  final _rows = <_CostRow>[];
  _Kind _kind = _Kind.recurring;
  TimeOfDay _time = const TimeOfDay(hour: 19, minute: 0);
  DateTime? _date;
  bool _busy = false;
  List<String> _errors = const [];
  String? _apiError;

  @override
  void dispose() {
    _name.dispose();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? today.add(const Duration(days: 1)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 365 * 2)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _addRow(String category) =>
      setState(() => _rows.add(_CostRow(category)));

  void _removeRow(_CostRow row) {
    setState(() => _rows.remove(row));
    row.dispose();
  }

  /// Validation messages; empty when the form can be sent.
  List<String> _validate() {
    final errors = <String>[];
    if (_kind == _Kind.recurring) {
      if (_days.isEmpty) errors.add('Pilih minimal satu hari main.');
    } else if (_date == null) {
      errors.add('Pilih tanggal acaranya.');
    }
    for (final (i, row) in _rows.indexed) {
      final n = i + 1;
      if (row.category.text.trim().isEmpty) {
        errors.add('Pos biaya $n belum ada namanya.');
      }
      final amount = int.tryParse(row.amount.text.trim());
      if (amount == null || amount <= 0) {
        errors.add('Jumlah pos biaya $n harus angka lebih dari Rp0.');
      }
    }
    return errors;
  }

  Map<String, dynamic> _body() {
    final name = _name.text.trim();
    return {
      'type': _kind == _Kind.recurring ? 'recurring' : 'one_off',
      if (name.isNotEmpty) 'name': name,
      if (_kind == _Kind.recurring) ...{
        'rrule':
            'FREQ=WEEKLY;BYDAY=${[for (final (code, _) in _weekdays)
              if (_days.contains(code)) code].join(',')}',
        'time': formatClock(_time.hour, _time.minute),
      } else
        'starts_at': wibIso(_date!, _time.hour, _time.minute),
      'cost_template': {
        'items': [
          for (final row in _rows)
            {
              'category': row.category.text.trim(),
              'amount': int.parse(row.amount.text.trim()),
              'scope': 'all',
              'paid_by_member_id': widget.hostMemberId,
            },
        ],
      },
    };
  }

  Future<void> _submit() async {
    if (_busy) return;
    final errors = _validate();
    setState(() {
      _errors = errors;
      _apiError = null;
    });
    if (errors.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.api.createEvent(widget.groupId, _body());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _kind == _Kind.oneOff
                ? 'Event dibuat. Sesinya sudah ada di draft.'
                : 'Event rutin dibuat. Sesi draft muncul 3 hari sebelum main.',
          ),
        ),
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(GroupRoutes.groupHomePath(widget.groupId));
      }
    } on ApiError catch (e) {
      if (mounted) setState(() => _apiError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _name,
          maxLength: 120,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Nama event (opsional)',
            helperText: 'Kosongkan untuk memakai nama grup.',
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<_Kind>(
          segments: const [
            ButtonSegment(value: _Kind.recurring, label: Text('Rutin')),
            ButtonSegment(value: _Kind.oneOff, label: Text('Sekali jalan')),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.single),
        ),
        const SizedBox(height: 16),
        if (_kind == _Kind.recurring) ...[
          Text('Hari main', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final (code, label) in _weekdays)
                FilterChip(
                  label: Text(label),
                  selected: _days.contains(code),
                  onSelected: (on) =>
                      setState(() => on ? _days.add(code) : _days.remove(code)),
                ),
            ],
          ),
        ] else ...[
          Text('Tanggal', style: textTheme.titleMedium),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today),
            label: Text(_date == null ? 'Pilih tanggal' : formatDate(_date!)),
            onPressed: _pickDate,
          ),
        ],
        const SizedBox(height: 16),
        Text('Jam (WIB)', style: textTheme.titleMedium),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.schedule),
          label: Text(formatClock(_time.hour, _time.minute)),
          onPressed: _pickTime,
        ),
        const SizedBox(height: 24),
        Text('Biaya default per sesi', style: textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Opsional. Setiap sesi baru langsung terisi pos biaya ini, bisa diubah per sesi.',
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final c in widget.categories)
              ActionChip(label: Text('+ $c'), onPressed: () => _addRow(c)),
            ActionChip(
              label: const Text('+ Pos lain'),
              onPressed: () => _addRow(''),
            ),
          ],
        ),
        for (final row in _rows)
          Padding(
            key: ObjectKey(row),
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: row.category,
                    decoration: const InputDecoration(labelText: 'Pos biaya'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: row.amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Jumlah',
                      prefixText: 'Rp',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Hapus pos biaya',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _removeRow(row),
                ),
              ],
            ),
          ),
        const SizedBox(height: 24),
        for (final error in _errors) ...[
          InlineError(error),
          const SizedBox(height: 8),
        ],
        if (_apiError != null) ...[
          InlineError(_apiError!),
          const SizedBox(height: 8),
        ],
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: BusyButtonChild(busy: _busy, label: 'Simpan event'),
        ),
      ],
    );
  }
}
