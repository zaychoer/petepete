import 'package:url_launcher/url_launcher.dart' as launcher;

/// Opens [url] outside the app (browser or the owning app). Returns false when
/// nothing could open it. Screens take one of these so tests can swap it.
typedef UrlLauncher = Future<bool> Function(Uri url);

/// The real launcher used by the running app.
Future<bool> openExternally(Uri url) =>
    launcher.launchUrl(url, mode: launcher.LaunchMode.externalApplication);
