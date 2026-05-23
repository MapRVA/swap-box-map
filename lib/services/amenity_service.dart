import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../config.dart';
import '../models/amenity.dart';

class OverpassResult {
  const OverpassResult({required this.amenities, this.osmBaseTimestamp});

  final List<Amenity> amenities;

  /// `osm3s.timestamp_osm_base` — the timestamp of the OSM data snapshot
  /// Overpass is serving from. Used to prune the recent-uploads cache: any
  /// cached entry uploaded before this is now reflected in [amenities].
  /// When reading directly from the OSM API (no replication lag), this is
  /// set to "now" so the cache prunes aggressively.
  final DateTime? osmBaseTimestamp;
}

class AmenityService {
  // Sent on every request. Public Overpass instances (notably
  // overpass-api.de) reject the default Dart UA with a 406, and ask all
  // clients to identify themselves with a name and a contact URL. OSM API
  // expects the same.
  static const String _userAgent = 'swap_box_map/1.0 (+https://maprva.org)';

  static const Set<String> _interestingAmenityValues = {
    'food_sharing',
    'public_bookcase',
    'give_box',
  };

  Future<OverpassResult> fetchInBbox({
    required double south,
    required double west,
    required double north,
    required double east,
    required String overpassUrl,
    required String osmApiUrl,
  }) {
    if (AppConfig.useOsmApiForReads) {
      return _fetchViaOsmApi(
        south: south,
        west: west,
        north: north,
        east: east,
        osmApiUrl: osmApiUrl,
      );
    }
    return _fetchViaOverpass(
      south: south,
      west: west,
      north: north,
      east: east,
      overpassUrl: overpassUrl,
    );
  }

  Future<OverpassResult> _fetchViaOverpass({
    required double south,
    required double west,
    required double north,
    required double east,
    required String overpassUrl,
  }) async {
    final bbox = '$south,$west,$north,$east';
    final query =
        '''
[out:json][timeout:25];
(
  node["amenity"="food_sharing"]($bbox);
  node["amenity"="public_bookcase"]($bbox);
  node["amenity"="give_box"]($bbox);
);
out meta;
''';
    final response = await http.post(
      Uri.parse(overpassUrl),
      headers: {'User-Agent': _userAgent},
      body: {'data': query},
    );
    if (response.statusCode != 200) {
      throw Exception(
        'Overpass returned ${response.statusCode}: ${response.body}',
      );
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final osm3s = body['osm3s'];
    final timestampRaw = osm3s is Map<String, dynamic>
        ? osm3s['timestamp_osm_base']
        : null;
    final timestamp = timestampRaw is String
        ? DateTime.tryParse(timestampRaw)
        : null;
    final elements = body['elements'] as List<dynamic>? ?? const [];
    final amenities = elements
        .whereType<Map<String, dynamic>>()
        .map(Amenity.fromOverpassNode)
        .whereType<Amenity>()
        .toList(growable: false);
    return OverpassResult(amenities: amenities, osmBaseTimestamp: timestamp);
  }

  /// OSM API `/api/0.6/map` returns every node/way/relation in the bbox as
  /// XML — unlike Overpass we can't ask the server to pre-filter by tag, so
  /// we do that locally. Suitable for small bbox dev testing; not what
  /// you'd want for a wide-area production query (hence the Overpass path).
  Future<OverpassResult> _fetchViaOsmApi({
    required double south,
    required double west,
    required double north,
    required double east,
    required String osmApiUrl,
  }) async {
    final uri = Uri.parse(
      '$osmApiUrl/api/0.6/map?bbox=$west,$south,$east,$north',
    );
    final response = await http.get(uri, headers: {'User-Agent': _userAgent});
    if (response.statusCode != 200) {
      throw Exception(
        'OSM API returned ${response.statusCode}: ${response.body}',
      );
    }
    final doc = XmlDocument.parse(response.body);
    final amenities = <Amenity>[];
    for (final node in doc.findAllElements('node')) {
      final map = _nodeXmlToMap(node);
      if (map == null) continue;
      final tags = map['tags'] as Map<String, String>;
      if (!_interestingAmenityValues.contains(tags['amenity'])) continue;
      final amenity = Amenity.fromOverpassNode(map);
      if (amenity != null) amenities.add(amenity);
    }
    return OverpassResult(
      amenities: amenities,
      // Reading directly from OSM master — no replication lag, so any
      // cache entry uploaded before "now" is reflected in the response.
      osmBaseTimestamp: DateTime.now(),
    );
  }

  Map<String, dynamic>? _nodeXmlToMap(XmlElement node) {
    final id = int.tryParse(node.getAttribute('id') ?? '');
    final lat = double.tryParse(node.getAttribute('lat') ?? '');
    final lon = double.tryParse(node.getAttribute('lon') ?? '');
    if (id == null || lat == null || lon == null) return null;
    final tags = <String, String>{};
    for (final tag in node.findElements('tag')) {
      final k = tag.getAttribute('k');
      final v = tag.getAttribute('v');
      if (k != null && v != null) tags[k] = v;
    }
    return {
      'id': id,
      'lat': lat,
      'lon': lon,
      'version': int.tryParse(node.getAttribute('version') ?? ''),
      'timestamp': node.getAttribute('timestamp'),
      'tags': tags,
    };
  }
}
