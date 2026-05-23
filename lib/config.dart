import 'package:flutter/foundation.dart';

/// Compile-time configuration for the app.
///
/// Build-time flags (pass with `--dart-define=NAME=true`):
///   * `USE_DEV_OSM_API` — point at the OSM sandbox at
///     `master.apis.dev.openstreetmap.org` instead of production OSM. Used
///     during development so writes don't pollute the real map.
///   * `USE_OSM_API_FOR_READS` — fetch POIs via OSM's `/api/0.6/map`
///     endpoint instead of Overpass. Necessary to read back from the dev
///     sandbox, which has no Overpass mirror.
///
/// To finish wiring up OSM sign-in, register an OAuth 2.0 application at
/// `${osmBaseUrl}/oauth2/applications` with:
///   * Redirect URI:   `swapboxmap://oauth2/redirect`
///   * Confidential application?  NO (this is a native/public client)
///   * Permissions:    "Read user preferences" + "Modify the map"
/// Then paste the issued Client ID into [_devOsmClientId] / [_prodOsmClientId].
class AppConfig {
  /// Defaults to `kDebugMode` so `flutter run` automatically targets the
  /// dev sandbox without burning a `--dart-define` on every invocation;
  /// release builds default to production. Pass
  /// `--dart-define=USE_DEV_OSM_API=false` (or `=true`) to override.
  static const bool useDevOsmApi = bool.fromEnvironment(
    'USE_DEV_OSM_API',
    defaultValue: kDebugMode,
  );

  static const bool useOsmApiForReads = bool.fromEnvironment(
    'USE_OSM_API_FOR_READS',
  );

  /// Client IDs are issued per-server — the dev sandbox and production OSM
  /// each maintain their own OAuth application registry. Register against
  /// the production server at `${osmBaseUrl}/oauth2/applications` and paste
  /// the value into [_prodOsmClientId] before shipping a release build.
  static const String _devOsmClientId =
      'tfUigIrXzm-FgaUUxuqgUJT1lf-zaN-osqb0iAm-WW4';
  static const String _prodOsmClientId =
      'Oy6USFCoMG0GJvXujAhDekHDngMlTFgQv56J8ABd1pQ';

  static const String osmClientId = useDevOsmApi
      ? _devOsmClientId
      : _prodOsmClientId;

  static const String osmBaseUrl = useDevOsmApi
      ? 'https://master.apis.dev.openstreetmap.org'
      : 'https://api.openstreetmap.org';

  static const String osmCustomUriScheme = 'swapboxmap';
  static const String osmRedirectUri = '$osmCustomUriScheme://oauth2/redirect';

  static const List<String> osmScopes = <String>['read_prefs', 'write_api'];

  static const String overpassUrl = 'https://overpass-api.de/api/interpreter';

  static const String mapStyleUrl =
      'https://styles.maprva.org/maptiler-basic.json';

  /// Below this zoom level we skip fetching and prompt the user to zoom in.
  /// OSM API caps bbox area at 0.25 sq-deg, and the endpoint also returns
  /// every node in the bbox (not just our amenity types), so we hold off
  /// until zoom is well above the cap — only zoom 17+ fetches in dev-read
  /// mode. Overpass pre-filters server-side and has no bbox cap, so a much
  /// looser threshold is fine.
  static const double minReadZoom = useOsmApiForReads ? 14.0 : 8.0;
}
