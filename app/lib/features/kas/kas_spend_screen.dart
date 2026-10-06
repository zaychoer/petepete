import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import '../../ui/rupiah.dart';
import 'kas_api.dart';
import 'kas_models.dart';
import 'kas_widgets.dart';

/// Belanja dari kas: the host records something bought out of the kas, e.g.
/// "Beli bola Rp120.000 dari kas". The server refuses when the amount is above the
/// kas balance and its message is shown as is. Pops `true` once it is recorded.
class KasSpendScreen extends StatefulWidget {
  const KasSpendScreen({super.key, required this.groupId});

  final int groupId;

  @override
  State<KasSpendScreen> createState() => _KasSpendScreenState();
}

class _KasSpendScreenState extends State<KasSpendScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _key = AttemptKey();
  KasApi? _kas;
  KasGroup? _group;
  int? _buyerId;
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
        _buyerId = group.meId;
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

  bool get _valid => amountError(_parsed) == null && _buyerId != null;

  String? get _preview {
    final group = _group;
    if (group == null || !_valid) return null;
    final note = _note.text.trim();
    final what = note.isEmpty ? 'Belanja' : 'Beli $note';
    final rp = formatRupiah(_parsed!);
    final buyer = _buyerId == group.meId
        ? null
        : group.members.firstWhere((m) => m.id == _buyerId).displayName;
    return buyer == null
        ? '$what $rp dari kas'
        : '$what $rp dari kas (oleh $buyer)';
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final note = _note.text.trim();
    try {
      await _kas!.recordKasSpend(
        widget.groupId,
        memberId: _buyerId!,
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
      appBar: AppBar(title: const Text('Belanja dari kas')),
      body: SafeArea(
        child: _loadError != null
            ? LoadErrorView(message: _loadError!, onRetry: _load)
            : group == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextField(
                    controller: _note,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => _changed(),
                    decoration: const InputDecoration(
                      labelText: 'Beli apa? (misal: bola)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  AmountField(
                    controller: _amount,
                    enabled: !_busy,
                    errorText: _amountError,
                    onChanged: (_) => _changed(),
                  ),
                  const SizedBox(height: 16),
                  MemberDropdown(
                    label: 'Yang beli',
                    members: group.members,
                    meId: group.meId,
                    value: _buyerId,
                    enabled: !_busy,
                    onChanged: (id) {
                      _buyerId = id;
                      _changed();
                    },
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
                    child: Text(_busy ? 'Mencatat…' : 'Catat belanja'),
                  ),
                ],
              ),
      ),
    );
  }
}
