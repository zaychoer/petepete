import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/api_error.dart';
import 'groups_api.dart';
import 'uri_launcher.dart';

/// The `wa.me` link that opens WhatsApp's chat picker with the invitation typed in.
/// No phone number: the host picks who to send it to.
Uri inviteWhatsAppUri({required String groupName, required String inviteUrl}) {
  final text =
      'Yuk gabung grup "$groupName" di Petepete! '
      'Buka link ini buat gabung: $inviteUrl';
  return Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
}

/// The Undang button: fetches the group's current invite link and opens WhatsApp with
/// the invitation. When WhatsApp can't be opened it shows the link to copy instead.
Future<void> inviteViaWhatsApp(
  BuildContext context,
  GroupsApi api,
  int groupId,
) async {
  final launch = LauncherScope.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final group = await api.group(groupId);
    final link = group.inviteUrl;
    if (link == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Hanya host yang bisa mengundang.')),
      );
      return;
    }
    final opened = await launch(
      inviteWhatsAppUri(groupName: group.name, inviteUrl: link),
    );
    if (!opened && context.mounted) await _showLink(context, link);
  } on ApiError catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

Future<void> _showLink(BuildContext context, String link) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('WhatsApp tidak bisa dibuka'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Salin link undangan ini dan kirim sendiri ya:'),
          const SizedBox(height: 12),
          SelectableText(link),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (context.mounted) Navigator.of(context).pop();
          },
          child: const Text('Salin link'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Tutup'),
        ),
      ],
    ),
  );
}
