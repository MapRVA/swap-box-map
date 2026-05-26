import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';

class SettingsService extends ChangeNotifier {
  static const _overpassUrlKey = 'overpass_url';
  static const _osmApiUrlKey = 'osm_api_url';
  static const _welcomeSeenKey = 'welcome_seen';

  SharedPreferences? _prefs;
  String? _overpassUrlOverride;
  String? _osmApiUrlOverride;
  bool _welcomeSeen = false;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  String get defaultOverpassUrl => AppConfig.overpassUrl;

  /// The endpoint to actually call. Falls back to the bundled default when the
  /// user hasn't set an override.
  String get overpassUrl => _overpassUrlOverride ?? defaultOverpassUrl;

  /// Null when the user is using the default; otherwise the user-set override.
  String? get overpassUrlOverride => _overpassUrlOverride;

  String get defaultOsmApiUrl => AppConfig.osmBaseUrl;

  /// OSM API base URL (no trailing slash). Used for OAuth, user details,
  /// uploads, and — when [AppConfig.useOsmApiForReads] is true — bbox reads.
  String get osmApiUrl => _osmApiUrlOverride ?? defaultOsmApiUrl;

  String? get osmApiUrlOverride => _osmApiUrlOverride;

  /// True once the user has tapped past the welcome screen. Persists across
  /// launches so the welcome screen only appears on the very first run.
  bool get welcomeSeen => _welcomeSeen;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _overpassUrlOverride = _prefs!.getString(_overpassUrlKey);
    _osmApiUrlOverride = _prefs!.getString(_osmApiUrlKey);
    _welcomeSeen = _prefs!.getBool(_welcomeSeenKey) ?? false;
    _initialized = true;
    notifyListeners();
  }

  Future<void> markWelcomeSeen() async {
    final prefs = _prefs;
    if (prefs == null || _welcomeSeen) return;
    await prefs.setBool(_welcomeSeenKey, true);
    _welcomeSeen = true;
    notifyListeners();
  }

  Future<void> resetWelcomeSeen() async {
    final prefs = _prefs;
    if (prefs == null || !_welcomeSeen) return;
    await prefs.remove(_welcomeSeenKey);
    _welcomeSeen = false;
    notifyListeners();
  }

  Future<void> setOverpassUrl(String? url) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == defaultOverpassUrl) {
      await prefs.remove(_overpassUrlKey);
      _overpassUrlOverride = null;
    } else {
      await prefs.setString(_overpassUrlKey, trimmed);
      _overpassUrlOverride = trimmed;
    }
    notifyListeners();
  }

  Future<void> setOsmApiUrl(String? url) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == defaultOsmApiUrl) {
      await prefs.remove(_osmApiUrlKey);
      _osmApiUrlOverride = null;
    } else {
      await prefs.setString(_osmApiUrlKey, trimmed);
      _osmApiUrlOverride = trimmed;
    }
    notifyListeners();
  }
}
