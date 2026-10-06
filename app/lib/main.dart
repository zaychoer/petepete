import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api/api_client.dart';
import 'app/app.dart';
import 'auth/auth_controller.dart';
import 'auth/token_store.dart';
import 'error_reporting.dart';

Future<void> main() async {
  await runWithErrorReporting(() {
    final tokens = SecureTokenStore();
    final api = ApiClient(
      baseUrl: apiBaseUrl,
      httpClient: http.Client(),
      tokens: tokens,
    );
    final auth = AuthController(api: api, tokens: tokens);
    runApp(PetepeteApp(api: api, auth: auth));
  });
}
