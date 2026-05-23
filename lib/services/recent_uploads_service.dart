import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/recent_upload.dart';

/// Cache of POIs we've just uploaded to OSM but that Overpass hasn't picked
/// up yet. Rendering merges these on top of the Overpass-loaded amenities
/// so the user doesn't see their edits "disappear" during replication lag.
/// See [pruneInBbox] for the cleanup story.
class RecentUploadsService extends ChangeNotifier {
  static const _dbFileName = 'recent_uploads.db';
  static const _table = 'recent_uploads';

  Database? _db;
  List<RecentUpload> _all = const [];
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// All cached entries, oldest-first.
  List<RecentUpload> get all => List.unmodifiable(_all);

  Future<void> init() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final path = p.join(docsDir.path, _dbFileName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            osm_id      INTEGER PRIMARY KEY,
            op          TEXT NOT NULL,
            version     INTEGER NOT NULL,
            lat         REAL NOT NULL,
            lon         REAL NOT NULL,
            tags        TEXT,
            uploaded_at INTEGER NOT NULL
          )
        ''');
      },
    );
    await _reload();
    _initialized = true;
    notifyListeners();
  }

  /// Insert/replace a batch of entries in a single transaction. Re-editing a
  /// node before Overpass catches up updates that row in place.
  Future<void> storeAll(Iterable<RecentUpload> entries) async {
    if (entries.isEmpty) return;
    final db = _requireDb();
    await db.transaction((txn) async {
      for (final entry in entries) {
        await txn.insert(
          _table,
          entry.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    await _reload();
    notifyListeners();
  }

  /// Delete cache rows inside [bounds] whose [RecentUpload.uploadedAt] is
  /// strictly before [before] — i.e., Overpass's data snapshot already
  /// includes them, so the cache row is redundant.
  Future<void> pruneInBbox({
    required LatLngBounds bounds,
    required DateTime before,
  }) async {
    final db = _requireDb();
    final deleted = await db.delete(
      _table,
      where:
          'uploaded_at < ? AND lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?',
      whereArgs: [
        before.millisecondsSinceEpoch,
        bounds.southwest.latitude,
        bounds.northeast.latitude,
        bounds.southwest.longitude,
        bounds.northeast.longitude,
      ],
    );
    if (deleted > 0) {
      await _reload();
      notifyListeners();
    }
  }

  Future<void> clear() async {
    final db = _requireDb();
    await db.delete(_table);
    await _reload();
    notifyListeners();
  }

  Future<void> _reload() async {
    final db = _requireDb();
    final rows = await db.query(_table, orderBy: 'uploaded_at ASC');
    _all = rows.map(RecentUpload.fromRow).toList(growable: false);
  }

  Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError('RecentUploadsService used before init() completed');
    }
    return db;
  }
}
