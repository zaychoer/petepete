import 'package:go_router/go_router.dart';

import '../account/account_screens.dart';
import 'event_form_screen.dart';
import 'group_home_screen.dart';
import 'group_list_screen.dart';
import 'group_name_screen.dart';
import 'group_paths.dart';
import 'join_screen.dart';
import 'members_screen.dart';
import 'payout_screen.dart';
import 'template_screen.dart';

int _groupId(GoRouterState state) =>
    int.parse(state.pathParameters['groupId']!);

/// A group URL with an id that isn't a number goes back to the landing screen.
String? _requireNumericGroupId(GoRouterState state) =>
    int.tryParse(state.pathParameters['groupId'] ?? '') == null ? '/' : null;

/// The routes of onboarding, the group home, roster, events, payout account, invite
/// links and the account screens. Added to the app router in `app/router.dart`.
final groupRoutes = <RouteBase>[
  GoRoute(
    path: GroupRoutes.groupsPath,
    name: GroupRoutes.groups,
    builder: (context, state) => const GroupListScreen(),
  ),
  // Before `:groupId`, which would otherwise swallow "new".
  GoRoute(
    path: GroupRoutes.newGroupPath,
    name: GroupRoutes.newGroup,
    builder: (context, state) => const GroupNameScreen(),
    routes: [
      GoRoute(
        path: 'template',
        name: GroupRoutes.template,
        redirect: (context, state) =>
            state.extra is String ? null : GroupRoutes.newGroupPath,
        builder: (context, state) =>
            TemplateScreen(groupName: state.extra! as String),
      ),
    ],
  ),
  GoRoute(
    path: '/groups/:groupId',
    name: GroupRoutes.groupHome,
    redirect: (context, state) => _requireNumericGroupId(state),
    builder: (context, state) => GroupHomeScreen(groupId: _groupId(state)),
    routes: [
      GoRoute(
        path: 'members',
        name: GroupRoutes.members,
        builder: (context, state) => MembersScreen(groupId: _groupId(state)),
      ),
      GoRoute(
        path: 'events/new',
        name: GroupRoutes.newEvent,
        builder: (context, state) => EventFormScreen(groupId: _groupId(state)),
      ),
      GoRoute(
        path: 'payout-account/register',
        name: GroupRoutes.payoutRegister,
        builder: (context, state) => PayoutScreen(groupId: _groupId(state)),
      ),
    ],
  ),
  GoRoute(
    path: '${GroupRoutes.joinPrefix}:token',
    name: GroupRoutes.join,
    builder: (context, state) => JoinScreen(
      token: state.pathParameters['token']!,
      claimMemberId: int.tryParse(state.uri.queryParameters['claim'] ?? ''),
    ),
  ),
  GoRoute(
    path: GroupRoutes.accountPath,
    name: GroupRoutes.account,
    builder: (context, state) => const AccountScreen(),
    routes: [
      GoRoute(
        path: 'hapus',
        name: GroupRoutes.deleteAccount,
        builder: (context, state) => const DeleteAccountScreen(),
      ),
    ],
  ),
];
