import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class OsmApiException implements Exception {
  const OsmApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'OsmApiException($statusCode): $body';
}

/// One row from the `<diffResult>` returned by `POST /changeset/{id}/upload`.
/// For creates: `oldId` is the negative placeholder we sent, `newId` is the
/// assigned OSM id. For modifies: `oldId == newId`. For deletes: `newId`
/// and `newVersion` are null (the node is gone).
class DiffResultEntry {
  const DiffResultEntry({required this.oldId, this.newId, this.newVersion});

  final int oldId;
  final int? newId;
  final int? newVersion;
}

/// Thin HTTP wrapper around the OSM API 0.6 editing endpoints. Stateless —
/// callers supply the access token and base URL on every call.
class OsmApiService {
  static const String _userAgent = 'swap_box_map/1.0 (+https://maprva.org)';

  Future<int> openChangeset({
    required String baseUrl,
    required String accessToken,
    required Map<String, String> tags,
  }) async {
    final builder = XmlBuilder();
    builder.element(
      'osm',
      nest: () {
        builder.element(
          'changeset',
          nest: () {
            for (final entry in tags.entries) {
              builder.element(
                'tag',
                attributes: {'k': entry.key, 'v': entry.value},
              );
            }
          },
        );
      },
    );
    final body = builder.buildDocument().toXmlString();

    final response = await http.put(
      Uri.parse('$baseUrl/api/0.6/changeset/create'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'text/xml',
        'User-Agent': _userAgent,
      },
      body: body,
    );
    if (response.statusCode != 200) {
      throw OsmApiException(response.statusCode, response.body);
    }
    final id = int.tryParse(response.body.trim());
    if (id == null) {
      throw OsmApiException(
        200,
        'Changeset created but server returned a non-integer id: '
        '${response.body}',
      );
    }
    return id;
  }

  Future<List<DiffResultEntry>> uploadDiff({
    required String baseUrl,
    required String accessToken,
    required int changesetId,
    required String osmChangeXml,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/0.6/changeset/$changesetId/upload'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'text/xml',
        'User-Agent': _userAgent,
      },
      body: osmChangeXml,
    );
    if (response.statusCode != 200) {
      throw OsmApiException(response.statusCode, response.body);
    }
    final doc = XmlDocument.parse(response.body);
    final results = <DiffResultEntry>[];
    for (final node in doc.findAllElements('node')) {
      final oldIdRaw = node.getAttribute('old_id');
      if (oldIdRaw == null) continue;
      final oldId = int.tryParse(oldIdRaw);
      if (oldId == null) continue;
      results.add(
        DiffResultEntry(
          oldId: oldId,
          newId: int.tryParse(node.getAttribute('new_id') ?? ''),
          newVersion: int.tryParse(node.getAttribute('new_version') ?? ''),
        ),
      );
    }
    return results;
  }

  Future<void> closeChangeset({
    required String baseUrl,
    required String accessToken,
    required int changesetId,
  }) async {
    final response = await http.put(
      Uri.parse('$baseUrl/api/0.6/changeset/$changesetId/close'),
      headers: {
        'Authorization': 'Bearer $accessToken',
        'User-Agent': _userAgent,
      },
    );
    if (response.statusCode != 200) {
      throw OsmApiException(response.statusCode, response.body);
    }
  }
}
