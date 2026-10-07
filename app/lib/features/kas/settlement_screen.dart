import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import '../../ui/rupiah.dart';
import 'kas_api.dart';
import 'kas_models.dart';
import 'kas_widgets.dart';

/// Catat pelunasan: the host records that one member paid another back, e.g.
/// "Saya ganti talangan Andi Rp50.000". Pops `true` once it is recorded.
class SettlementScreen extends StatefulWidget {
  const SettlementScreen({super.key, required this.groupId});

  final int groupId;

  @override
  State<SettlementScreen> createState() => _SettlementScreenState();
}

class _SettlementScreenState extends State<SettlementScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _key = AttemptKey();
  KasApi? _kas;
  KasGroup? _group;
  int? _payerId;
  int? _payeeId;
  String? _loadError;
  String? _error;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_kas == null) {
      _kas = KasApi(AppScope.of(context).api);
      _load();
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final group = await _kas!.group(widget.groupId);
      if (!mounted) return;
      setState(() {
        _group = group;
        _payerId = group.meId;
      });
    } on ApiError catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  void _changed() => setState(() {
    _key.reset();
    _error = null;
  });

  int? get _parsed => parseAmount(_amount.text);

  String? get _amountError =>
      _amount.text.isEmpty ? null : amountError(_parsed);

  String? get _sameError => _payerId != null && _payerId == _payeeId
      ? 'Pembayar dan penerima tidak boleh orang yang sama.'
      : null;

  bool get _valid =>
      amountError(_parsed) == null &&
      _payerId != null &&
      _payeeId != null &&
      _payerId != _payeeId;

  String? get _preview {
    final group = _group;
    if (group == null || !_valid) return null;
    String name(int id) =>
        group.members.firstWhere((m) => m.id == id).displayName;
    final rp = formatRupiah(_parsed!);
    return _payerId == group.meId
        ? 'Saya ganti talangan ${name(_payeeId!)} $rp'
        : '${name(_payerId!)} bayar $rp ke ${name(_payeeId!)}';
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final note = _note.text.trim();
    try {
      await _kas!.recordSettlement(
        widget.groupId,
        payerId: _payerId!,
        payeeId: _payeeId!,
        amount: _parsed!,
        note: note.isEmpty ? null : note,
        idempotencyKey: _key.current,
      );
      _key.reset();
      if (mounted) Navigator.of(context).pop(true);
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    return Scaffold(
      appBar: AppBar(title: const Text('Catat pelunasan')),
      body: SafeArea(
        child: _loadError != null
            ? LoadErrorView(message: _loadError!, onRetry: _load)
            : group == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  MemberDropdown(
                    label: 'Yang bayar',
                    members: group.members,
                    meId: group.meId,
                    value: _payerId,
                    enabled: !_busy,
                    onChanged: (id) {
                      _payerId = id;
                      _changed();
                    },
                  ),
                  const SizedBox(height: 16),
                  MemberDropdown(
                    label: 'Dibayar ke',
                    members: group.members,
                    meId: group.meId,
                    value: _payeeId,
                    enabled: !_busy,
                    onChanged: (id) {
                      _payeeId = id;
                      _changed();
                    },
                  ),
                  if (_sameError != null) ...[
                    const SizedBox(height: 8),
                    InlineError(_sameError!),
                  ],
                  const SizedBox(height: 16),
                  AmountField(
                    controller: _amount,
                    enabled: !_busy,
                    errorText: _amountError,
                    onChanged: (_) => _changed(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _note,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => _changed(),
                    decoration: const InputDecoration(
                      labelText: 'Catatan (boleh kosong)',
                    ),
                  ),
                  if (_preview != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _preview!,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    InlineError(_error!),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _valid && !_busy ? _submit : null,
                    child: Text(_busy ? 'Mencatat…' : 'Catat pelunasan'),
                  ),
                ],
              ),
      ),
    );
  }
}
