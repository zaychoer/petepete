import 'package:flutter/material.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import 'kas_api.dart';
import 'kas_models.dart';
import 'kas_widgets.dart';

/// Asks the host for a reason and posts the Koreksi of a settlement or kas spend.
/// Pops `true` once the correction is recorded.
///
/// The `Idempotency-Key` is made on the first tap of "Koreksi" and reused when the
/// host retries after a failure with the same reason; editing the reason starts a new
/// action.
class CorrectionDialog extends StatefulWidget {
  const CorrectionDialog({super.key, required this.txn});

  final KasTxn txn;

  @override
  State<CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<CorrectionDialog> {
  final _reason = TextEditingController();
  final _key = AttemptKey();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _valid => _reason.text.trim().isNotEmpty;

  Future<void> _submit() async {
    final api = KasApi(AppScope.of(context).api);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await api.correct(
        widget.txn.id,
        reason: _reason.text.trim(),
        idempotencyKey: _key.current,
      );
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
    return AlertDialog(
      title: const Text('Koreksi catatan'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.txn.description),
            const SizedBox(height: 8),
            const Text(
              'Catatan ini dibalik, bukan dihapus. Catatan asli dan pembaliknya tetap tampil di riwayat.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _reason,
              enabled: !_busy,
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
              onChanged: (_) => setState(() {
                _key.reset();
                _error = null;
              }),
              decoration: const InputDecoration(
                labelText: 'Alasan koreksi (wajib)',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              InlineError(_error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Batal'),
        ),
        FilledButton(
          onPressed: _valid && !_busy ? _submit : null,
          style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
          child: Text(_busy ? 'Mengoreksi…' : 'Koreksi'),
        ),
      ],
    );
  }
}
