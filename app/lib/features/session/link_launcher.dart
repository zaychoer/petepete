import 'package:url_launcher/url_launcher.dart';

/// Opens a link outside the app (WhatsApp). Injected so tests never leave the app.
abstract class LinkLauncher {
  /// Returns false when nothing could handle [uri].
  Future<bool> open(Uri uri);
}

/// The real thing: hands the link to the OS (`wa.me` opens WhatsApp).
class SystemLinkLauncher implements LinkLauncher {
  const SystemLinkLauncher();

  @override
  Future<bool> open(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}
