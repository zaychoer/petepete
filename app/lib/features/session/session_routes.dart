import 'package:go_router/go_router.dart';

import 'link_launcher.dart';
import 'preview_screen.dart';
import 'session_screen.dart';

/// Route names of the session screens.
abstract final class SessionRoutes {
  /// `/groups/:groupId/sessions/:sessionId`: costs and attendance while a draft,
  /// bills and payment status once issued. The group home links here.
  static const detail = 'sessionDetail';

  /// `.../preview`: the bill preview with the Kirim tagihan button.
  static const preview = 'sessionPreview';
}

/// The session screens' routes. [launcher] opens WhatsApp links; tests inject a fake.
GoRoute sessionRoute({LinkLauncher launcher = const SystemLinkLauncher()}) {
  return GoRoute(
    path: '/groups/:groupId/sessions/:sessionId',
    name: SessionRoutes.detail,
    builder: (context, state) => SessionScreen(
      groupId: int.parse(state.pathParameters['groupId']!),
      sessionId: int.parse(state.pathParameters['sessionId']!),
      launcher: launcher,
    ),
    routes: [
      GoRoute(
        path: 'preview',
        name: SessionRoutes.preview,
        builder: (context, state) => PreviewScreen(
          groupId: int.parse(state.pathParameters['groupId']!),
          sessionId: int.parse(state.pathParameters['sessionId']!),
        ),
      ),
    ],
  );
}
