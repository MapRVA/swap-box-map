import 'dart:convert';

enum PendingEditOp {
  create,
  modify,
  delete;

  static PendingEditOp fromName(String name) {
    for (final op in PendingEditOp.values) {
      if (op.name == name) return op;
    }
    throw ArgumentError('Unknown PendingEditOp: $name');
  }
}

/// Categorization of a `modify` edit for queue-review UI. Flags are not
/// mutually exclusive — a single modify can show any combination of these.
class ModifyKind {
  const ModifyKind({
    required this.checked,
    required this.moved,
    required this.editedMetadata,
  });

  static const empty = ModifyKind(
    checked: false,
    moved: false,
    editedMetadata: false,
  );

  /// Only the `check_date` tag changed.
  final bool checked;

  /// Lat/lon changed.
  final bool moved;

  /// Some tag other than `check_date` was added, removed, or modified.
  final bool editedMetadata;

  bool get isEmpty => !checked && !moved && !editedMetadata;
}

/// A queued OSM edit waiting to be uploaded. The queue is dumb transport —
/// callers fully populate `newTags` (including any `check_date` value) before
/// enqueueing.
class PendingEdit {
  const PendingEdit({
    required this.localId,
    required this.op,
    this.osmId,
    this.baseVersion,
    this.originalLat,
    this.originalLon,
    this.originalTags,
    this.newLat,
    this.newLon,
    this.newTags,
    required this.queuedAt,
  });

  /// Stable local identifier (uuid). The OSM negative-int placeholder used in
  /// upload XML is assigned at upload time, not stored here.
  final String localId;

  final PendingEditOp op;

  /// OSM node ID. Null for `create` (the node doesn't exist yet).
  final int? osmId;

  /// OSM version of the node at the moment editing started. Sent on upload so
  /// OSM can detect concurrent changes. Null for `create`.
  final int? baseVersion;

  /// Snapshot of the node at the moment editing started. Null for `create`.
  /// Used to derive [modifyKind] and to send the full updated tag map on
  /// modify upload.
  final double? originalLat;
  final double? originalLon;
  final Map<String, String>? originalTags;

  /// Desired end state. Null for `delete`.
  final double? newLat;
  final double? newLon;
  final Map<String, String>? newTags;

  final DateTime queuedAt;

  ModifyKind get modifyKind {
    if (op != PendingEditOp.modify) return ModifyKind.empty;
    final origTags = originalTags ?? const <String, String>{};
    final newT = newTags ?? const <String, String>{};
    final moved = originalLat != newLat || originalLon != newLon;
    final changedKeys = <String>{
      ...origTags.keys.where((k) => origTags[k] != newT[k]),
      ...newT.keys.where((k) => newT[k] != origTags[k]),
    };
    final checked = changedKeys.contains('check_date');
    final otherChanged = changedKeys.any((k) => k != 'check_date');
    return ModifyKind(
      checked: checked,
      moved: moved,
      editedMetadata: otherChanged,
    );
  }

  Map<String, Object?> toRow() => {
    'local_id': localId,
    'op': op.name,
    'osm_id': osmId,
    'base_version': baseVersion,
    'original_lat': originalLat,
    'original_lon': originalLon,
    'original_tags': originalTags == null ? null : jsonEncode(originalTags),
    'new_lat': newLat,
    'new_lon': newLon,
    'new_tags': newTags == null ? null : jsonEncode(newTags),
    'queued_at': queuedAt.millisecondsSinceEpoch,
  };

  static PendingEdit fromRow(Map<String, Object?> row) {
    return PendingEdit(
      localId: row['local_id'] as String,
      op: PendingEditOp.fromName(row['op'] as String),
      osmId: row['osm_id'] as int?,
      baseVersion: row['base_version'] as int?,
      originalLat: row['original_lat'] as double?,
      originalLon: row['original_lon'] as double?,
      originalTags: _decodeTags(row['original_tags']),
      newLat: row['new_lat'] as double?,
      newLon: row['new_lon'] as double?,
      newTags: _decodeTags(row['new_tags']),
      queuedAt: DateTime.fromMillisecondsSinceEpoch(row['queued_at'] as int),
    );
  }

  static Map<String, String>? _decodeTags(Object? value) {
    if (value == null) return null;
    final decoded = jsonDecode(value as String) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, v.toString()));
  }
}
