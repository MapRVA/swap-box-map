import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2_client/oauth2_helper.dart';

import '../config.dart';
import '../models/osm_user.dart';
import 'osm_oauth2_client.dart';
import 'settings_service.dart';

class OsmAuthService extends ChangeNotifier {
  OsmAuthService({required this.settingsService}) {
    _baseUrl = settingsService.osmApiUrl;
    _rebuildHelper();
    settingsService.addListener(_onSettingsChanged);
  }

  final SettingsService settingsService;

  late OAuth2Helper _helper;
  late String _baseUrl;

  OsmUser? _currentUser;
  bool _initialized = false;

  OsmUser? get currentUser => _currentUser;
  bool get isSignedIn => _currentUser != null;
  bool get isInitialized => _initialized;

  void _rebuildHelper() {
    _helper = OAuth2Helper(
      OsmOAuth2Client(baseUrl: _baseUrl),
      grantType: OAuth2Helper.authorizationCode,
      clientId: AppConfig.osmClientId,
      scopes: AppConfig.osmScopes,
      enablePKCE: true,
    );
  }

  Future<void> _onSettingsChanged() async {
    final newUrl = settingsService.osmApiUrl;
    if (newUrl == _baseUrl) return;
    // Switching API URLs invalidates the current session: tokens are
    // bound to whichever OSM server issued them, and the OAuth helper's
    // authorize/token endpoints point at the old base URL. Clear the
    // session and rebuild against the new URL.
    await _helper.removeAllTokens();
    _currentUser = null;
    _baseUrl = newUrl;
    _rebuildHelper();
    notifyListeners();
  }

  @override
  void dispose() {
    settingsService.removeListener(_onSettingsChanged);
    super.dispose();
  }

  Future<void> init() async {
    try {
      final stored = await _helper.getTokenFromStorage();
      final accessToken = stored?.accessToken;
      if (stored != null && stored.isValid() && accessToken != null) {
        _currentUser = await _fetchUserDetails(accessToken);
        _primeAvatarCache(_currentUser?.imageUrl);
      }
    } catch (_) {
      await _helper.removeAllTokens();
      _currentUser = null;
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> signIn() async {
    final token = await _helper.getToken();
    final accessToken = token.accessToken;
    if (!token.isValid() || accessToken == null) {
      throw Exception('OSM sign-in did not return a valid token.');
    }
    _currentUser = await _fetchUserDetails(accessToken);
    _primeAvatarCache(_currentUser?.imageUrl);
    notifyListeners();
  }

  /// Fire-and-forget download of the avatar so it lands in the on-disk cache
  /// used by `CachedNetworkImageProvider`. Failures are non-fatal — the next
  /// display will fall back to the network.
  void _primeAvatarCache(String? url) {
    if (url == null) return;
    DefaultCacheManager().downloadFile(url).catchError((_) {
      return Future<FileInfo>.error('avatar cache prime failed');
    });
  }

  Future<void> signOut() async {
    await _helper.removeAllTokens();
    _currentUser = null;
    notifyListeners();
  }

  /// Returns a usable access token, preflight-refreshing the stored token
  /// when it's expired and a refresh token is available. Returns null when
  /// there's nothing stored, when the stored token is expired and can't be
  /// refreshed, or when the refresh exchange fails — the caller should
  /// treat null as "user needs to sign in again" and not retry on its own.
  Future<String?> getValidAccessToken() async {
    try {
      final stored = await _helper.getTokenFromStorage();
      if (stored == null) return null;
      final token = stored.accessToken;
      if (stored.isValid() && token != null) return token;
      if (stored.refreshToken == null) return null;
      final refreshed = await _helper.refreshToken(stored);
      if (refreshed.isValid() && refreshed.accessToken != null) {
        return refreshed.accessToken;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<OsmUser> _fetchUserDetails(String accessToken) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/api/0.6/user/details.json'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (response.statusCode != 200) {
      throw Exception(
        'Failed to fetch OSM user details (${response.statusCode}).',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return OsmUser.fromJson(body['user'] as Map<String, dynamic>);
  }
}
