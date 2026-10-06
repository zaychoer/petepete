/// Paths and route names of the group screens. Other features link to these.
abstract final class GroupRoutes {
  static const groups = 'groups';
  static const newGroup = 'newGroup';
  static const template = 'template';
  static const groupHome = 'groupHome';
  static const members = 'members';
  static const newEvent = 'newEvent';
  static const payoutRegister = 'payoutRegister';
  static const join = 'join';
  static const account = 'account';
  static const deleteAccount = 'deleteAccount';

  static const groupsPath = '/groups';
  static const newGroupPath = '/groups/new';
  static const templatePath = '/groups/new/template';
  static const joinPrefix = '/join/';
  static const accountPath = '/akun';
  static const deleteAccountPath = '/akun/hapus';

  static String groupHomePath(int groupId) => '/groups/$groupId';
  static String membersPath(int groupId) => '/groups/$groupId/members';
  static String newEventPath(int groupId) => '/groups/$groupId/events/new';
  static String sessionPath(int groupId, int sessionId) =>
      '/groups/$groupId/sessions/$sessionId';
}
