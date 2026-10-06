import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_error.dart';
import '../../app/app_scope.dart';
import '../../ui/inline_error.dart';
import '../../ui/rupiah.dart';
import 'async_body.dart';
import 'group_paths.dart';
import 'group_templates.dart';
import 'groups_api.dart';

/// Step 2 of onboarding: pick a template, which fills in the default cost items, then
/// create the group and land on its beranda (step 3).
class TemplateScreen extends StatefulWidget {
  const TemplateScreen({super.key, required this.groupName});

  final String groupName;

  @override
  State<TemplateScreen> createState() => _TemplateScreenState();
}

class _TemplateScreenState extends State<TemplateScreen> {
  String? _selected;
  bool _busy = false;
  String? _error;

  Future<void> _create() async {
    final template = _selected;
    if (template == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await GroupsApi(
        AppScope.of(context).api,
      ).createGroup(name: widget.groupName, template: template);
      if (mounted) context.go(GroupRoutes.groupHomePath(id));
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                children: [
                  Text('Pilih template', style: textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Template mengisi pos biaya default untuk "${widget.groupName}". '
                    'Bisa diubah kapan saja.',
                    style: textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Pembulatan patungan: ${formatRupiah(defaultRoundingUnit)}',
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  RadioGroup<String>(
                    groupValue: _selected,
                    onChanged: (v) => setState(() => _selected = v),
                    child: Column(
                      children: [
                        for (final t in groupTemplates)
                          _TemplateCard(
                            template: t,
                            selected: _selected == t.name,
                            onTap: () => setState(() => _selected = t.name),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    InlineError(_error!),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _selected != null && !_busy ? _create : null,
                    child: BusyButtonChild(busy: _busy, label: 'Buat grup'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.template,
    required this.selected,
    required this.onTap,
  });

  final GroupTemplate template;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).dividerColor,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Radio<String>(value: template.name),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      template.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in template.costCategories)
                          Chip(
                            label: Text(c),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
