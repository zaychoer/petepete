import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_scope.dart';
import 'async_body.dart';
import 'group_name_screen.dart';
import 'group_paths.dart';
import 'groups_api.dart';

/// Where a logged-in user lands. A new host sees "Nama grup" right here (screen 1 of
/// 3: nama grup, template, beranda); someone with one group goes straight to its
/// beranda; someone with several picks one in the group list.
class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final groups = GroupsApi(AppScope.of(context).api);
    return AsyncBody<List<GroupSummary>>(
      fullScreen: true,
      load: groups.listGroups,
      builder: (context, list, _) {
        if (list.isEmpty) return const GroupNameScreen();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          context.go(
            list.length == 1
                ? GroupRoutes.groupHomePath(list.single.id)
                : GroupRoutes.groupsPath,
          );
        });
        return const Center(child: CircularProgressIndicator());
      },
    );
  }
}
