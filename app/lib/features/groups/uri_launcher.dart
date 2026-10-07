import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Opens [uri] in another app (WhatsApp, browser). Returns false when nothing could
/// handle it.
typedef UriLauncher = Future<bool> Function(Uri uri);

Future<bool> _launchExternally(Uri uri) => url_launcher.launchUrl(
  uri,
  mode: url_launcher.LaunchMode.externalApplication,
);

/// Lets tests (and only tests) swap the launcher: put a [LauncherScope] above the app
/// and read back what was launched. Without one, screens use `url_launcher`.
class LauncherScope extends InheritedWidget {
  const LauncherScope({super.key, required this.launch, required super.child});

  final UriLauncher launch;

  /// The launcher to use below [context].
  static UriLauncher of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<LauncherScope>()?.launch ??
      _launchExternally;

  @override
  bool updateShouldNotify(LauncherScope oldWidget) =>
      launch != oldWidget.launch;
}
