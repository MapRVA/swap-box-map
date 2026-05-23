import 'package:oauth2_client/oauth2_client.dart';

import '../config.dart';

class OsmOAuth2Client extends OAuth2Client {
  OsmOAuth2Client({required String baseUrl})
    : super(
        authorizeUrl: '$baseUrl/oauth2/authorize',
        tokenUrl: '$baseUrl/oauth2/token',
        redirectUri: AppConfig.osmRedirectUri,
        customUriScheme: AppConfig.osmCustomUriScheme,
      );
}
