import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_scope.dart';
import 'async_body.dart';
import 'group_paths.dart';
import 'groups_api.dart';

/// Every group the user is in, to pick one or start a new one.
class GroupListScreen extends StatelessWidget {
  const GroupListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final api = GroupsApi(AppScope.of(context).api);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Grupku'),
        actions: [
          IconButton(
            tooltip: 'Akun',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => context.pushNamed(GroupRoutes.account),
          ),
        ],
      ),
      body: AsyncBody<List<GroupSummary>>(
        load: api.listGroups,
        builder: (context, groups, reload) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final g in groups)
              Card(
                child: ListTile(
                  title: Text(g.name),
                  subtitle: Text(
                    [
                      if (g.template != null) g.template!,
                      g.roleLabel,
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go(GroupRoutes.groupHomePath(g.id)),
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Buat grup baru'),
              onPressed: () => context.pushNamed(GroupRoutes.newGroup),
            ),
          ],
        ),
      ),
    );
  }
}
