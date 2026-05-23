import 'dart:convert';

enum RecentUploadOp {
  create,
  modify,
  delete;

  static RecentUploadOp fromName(String name) {
    for (final op in RecentUploadOp.values) {
      if (op.name == name) return op;
    }
    throw ArgumentError('Unknown RecentUploadOp: $name');
  }
}

/// A POI we just uploaded to OSM, cached locally so the user keeps seeing
/// their edit even while Overpass replication is lagging behind. Pruned
/// when an Overpass refetch's `osm3s.timestamp_osm_base` proves Overpass has
/// caught up to (or past) this entry's [uploadedAt].
class RecentUpload {
  const RecentUpload({
    required this.osmId,
    required this.op,
    required this.version,
    required this.lat,
    required this.lon,
    required this.tags,
    required this.uploadedAt,
  });

  /// Real OSM node id. For creates this comes from the diffResult's
  /// `new_id`; for modify/delete it's the same id we sent.
  final int osmId;

  final RecentUploadOp op;

  /// Post-upload version: diffResult's `new_version` when present, else
  /// `baseVersion + 1` (a defensible fallback for deletes).
  final int version;

  /// For deletes, the pre-deletion location — kept so the bbox-scoped
  /// pruning query has lat/lon to filter on.
  final double lat;
  final double lon;

  /// Null for deletes.
  final Map<String, String>? tags;

  final DateTime uploadedAt;

  Map<String, Object?> toRow() => {
    'osm_id': osmId,
    'op': op.name,
    'version': version,
    'lat': lat,
    'lon': lon,
    'tags': tags == null ? null : jsonEncode(tags),
    'uploaded_at': uploadedAt.millisecondsSinceEpoch,
  };

  static RecentUpload fromRow(Map<String, Object?> row) {
    final tagsRaw = row['tags'] as String?;
    return RecentUpload(
      osmId: row['osm_id'] as int,
      op: RecentUploadOp.fromName(row['op'] as String),
      version: row['version'] as int,
      lat: row['lat'] as double,
      lon: row['lon'] as double,
      tags: tagsRaw == null
          ? null
          : (jsonDecode(tagsRaw) as Map<String, dynamic>).map(
              (k, v) => MapEntry(k, v.toString()),
            ),
      uploadedAt: DateTime.fromMillisecondsSinceEpoch(
        row['uploaded_at'] as int,
      ),
    );
  }
}
