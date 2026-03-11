import 'dart:convert';

import 'native_bridge.dart';
import 'preferences_service.dart';
import '../constants.dart';

/// Reads gateway configuration from openclaw.json.
///
/// Currently only exposes the gateway auth token at:
///   gateway.auth.token
class GatewayConfigService {
  static const _configPath = '/root/.openclaw/openclaw.json';

  /// Read `gateway.auth.token` from the gateway config file.
  ///
  /// Returns null if the config file doesn't exist, is invalid JSON,
  /// or the token field is missing.
  static Future<String?> readGatewayAuthToken() async {
    try {
      final content = await NativeBridge.readRootfsFile(_configPath);
      if (content == null || content.isEmpty) return null;

      final config = jsonDecode(content) as Map<String, dynamic>;
      final gateway = config['gateway'] as Map<String, dynamic>?;
      final auth = gateway?['auth'] as Map<String, dynamic>?;
      final token = auth?['token'] as String?;
      if (token == null || token.isEmpty) return null;
      _saveTokenUrl(token);
      return token;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveTokenUrl(String token) async {
    final prefs = PreferencesService();
    await prefs.init();
    prefs.dashboardUrl = "${AppConstants.gatewayUrl}/#token=$token";
  }
}
