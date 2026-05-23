import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/pending_edit.dart';

class EditQueueService extends ChangeNotifier {
  static const _dbFileName = 'swap_box_map.db';
  static const _table = 'pending_edits';

  Database? _db;
  List<PendingEdit> _pending = const [];
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Queue contents ordered oldest-first. Returned as an unmodifiable view so
  /// callers can't mutate internal state.
  List<PendingEdit> get pending => List.unmodifiable(_pending);

  int get length => _pending.length;

  Future<void> init() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final path = p.join(docsDir.path, _dbFileName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            local_id       TEXT PRIMARY KEY,
            op             TEXT NOT NULL,
            osm_id         INTEGER,
            base_version   INTEGER,
            original_lat   REAL,
            original_lon   REAL,
            original_tags  TEXT,
            new_lat        REAL,
            new_lon        REAL,
            new_tags       TEXT,
            queued_at      INTEGER NOT NULL
          )
        ''');
        // Enforces "at most one pending edit per existing node" at the DB
        // level. Creates (osm_id IS NULL) are unconstrained.
        await db.execute('''
          CREATE UNIQUE INDEX idx_${_table}_osm_id
            ON $_table(osm_id) WHERE osm_id IS NOT NULL
        ''');
      },
    );
    await _reload();
    _initialized = true;
    notifyListeners();
  }

  /// Inserts an edit. For `modify`/`delete`, any existing queued edit on the
  /// same node is replaced (coalescing — the queue always reflects the latest
  /// intended end state for each node). For `create`, every call inserts a
  /// new entry.
  Future<void> enqueue(PendingEdit edit) async {
    final db = _requireDb();
    await db.transaction((txn) async {
      if (edit.osmId != null) {
        await txn.delete(_table, where: 'osm_id = ?', whereArgs: [edit.osmId]);
      }
      await txn.insert(
        _table,
        edit.toRow(),
        // Re-enqueueing with the same local_id replaces the row. Used to
        // resume editing a queued create without orphaning a duplicate.
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    await _reload();
    notifyListeners();
  }

  Future<void> remove(String localId) async {
    final db = _requireDb();
    await db.delete(_table, where: 'local_id = ?', whereArgs: [localId]);
    await _reload();
    notifyListeners();
  }

  Future<void> clear() async {
    final db = _requireDb();
    await db.delete(_table);
    await _reload();
    notifyListeners();
  }

  Future<void> _reload() async {
    final db = _requireDb();
    final rows = await db.query(_table, orderBy: 'queued_at ASC');
    _pending = rows.map(PendingEdit.fromRow).toList(growable: false);
  }

  Database _requireDb() {
    final db = _db;
    if (db == null) {
      throw StateError('EditQueueService used before init() completed');
    }
    return db;
  }
}
