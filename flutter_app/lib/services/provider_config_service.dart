import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/ai_provider.dart';
import 'native_bridge.dart';

/// Reads and writes AI provider configuration in openclaw.json.
class ProviderConfigService {
  static const _configPath = '/root/.openclaw/openclaw.json';

  /// Escape a string for use as a single-quoted shell argument.
  static String _shellEscape(String s) {
    return "'${s.replaceAll("'", "'\\''")}'";
  }

  /// Read the current config and return a map with:
  /// - `activeModel`: the current primary model string (or null)
  /// - `providers`: Map&lt;providerId, {apiKey, model}&gt; for configured providers
  static Future<Map<String, dynamic>> readConfig() async {
    try {
      final content = await NativeBridge.readRootfsFile(_configPath);
      if (content == null || content.isEmpty) {
        return {'activeModel': null, 'providers': <String, dynamic>{}};
      }
      final config = jsonDecode(content) as Map<String, dynamic>;

      // Extract active model
      String? activeModel;
      final agents = config['agents'] as Map<String, dynamic>?;
      if (agents != null) {
        final defaults = agents['defaults'] as Map<String, dynamic>?;
        if (defaults != null) {
          final model = defaults['model'] as Map<String, dynamic>?;
          if (model != null) {
            activeModel = model['primary'] as String?;
          }
        }
      }

      // Extract configured providers
      final providers = <String, dynamic>{};
      final modelsSection = config['models'] as Map<String, dynamic>?;
      if (modelsSection != null) {
        final providerEntries =
            modelsSection['providers'] as Map<String, dynamic>?;
        if (providerEntries != null) {
          for (final entry in providerEntries.entries) {
            providers[entry.key] = entry.value;
          }
        }
      }

      return {'activeModel': activeModel, 'providers': providers};
    } catch (_) {
      return {'activeModel': null, 'providers': <String, dynamic>{}};
    }
  }

  /// Save a provider's API key and set its model as the active model.
  /// Tries a Node.js one-liner in proot first, then falls back to a direct
  /// file write via NativeBridge.writeRootfsFile if proot/DNS is unavailable.
  static Future<void> saveProviderConfig({
    required AiProvider provider,
    required String apiKey,
    required String model,
  }) async {
    // Dart Map/List -> jsonEncode。
    final providerMap = <String, dynamic>{
      "baseUrl": provider.baseUrl,
      "apiKey": apiKey,
      "models": [
        {
          "id": model,
          "name": model,
          "reasoning": false,
          "input": ["text", "image"],
          "cost": {
            "input": 0,
            "output": 0,
            "cacheRead": 0,
            "cacheWrite": 0,
          },
          "contextWindow": 200000,
          "maxTokens": 8192,
        }
      ]
    };

    if (provider.api.trim().isNotEmpty) {
      providerMap["api"] = provider.api;
    }

    final providerJson = jsonEncode(providerMap);

    final commands = <String>[
      'openclaw config set models.providers.${provider.id} --json \'$providerJson\'',
      "openclaw models set '${provider.id}/$model'",
      // 'openclaw gateway restart',
    ];

    try {
      for (var i = 0; i < commands.length; i++) {
        final cmd = commands[i];

        if (kDebugMode) {
          debugPrint(
              '[ProviderConfigService] runInProot(${i + 1}/${commands.length}) cmd: $cmd');
        }

        await NativeBridge.runInProot(cmd);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ProviderConfigService] Setup error: $e');
      }
    }
  }

  /// Remove a provider's config entry and clear the active model if it
  /// belonged to this provider.
  static Future<void> removeProviderConfig({
    required AiProvider provider,
  }) async {
    final providerIdJson = jsonEncode(provider.id);
    // Build a list of this provider's known model names so we can clear
    // the active model if it matches one of them.
    final modelsJson = jsonEncode(provider.defaultModels);

    final script = '''
const fs = require("fs");
const p = "$_configPath";
let c = {};
try { c = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
if (c.models && c.models.providers) {
  delete c.models.providers[$providerIdJson];
}
const known = $modelsJson;
if (c.agents && c.agents.defaults && c.agents.defaults.model) {
  const cur = c.agents.defaults.model.primary;
  if (cur && known.some(m => cur.includes(m))) {
    delete c.agents.defaults.model.primary;
  }
}
fs.writeFileSync(p, JSON.stringify(c, null, 2));
''';
    await NativeBridge.runInProot(
      'node -e ${_shellEscape(script)}',
      timeout: 15,
    );
  }
}
