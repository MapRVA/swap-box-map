import 'package:xml/xml.dart';

import '../models/amenity.dart';
import '../models/pending_edit.dart';
import '../models/recent_upload.dart';
import 'edit_queue_service.dart';
import 'osm_api_service.dart';
import 'osm_auth_service.dart';
import 'recent_uploads_service.dart';
import 'settings_service.dart';

sealed class UploadOutcome {
  const UploadOutcome();
}

class UploadSuccess extends UploadOutcome {
  const UploadSuccess(this.count);
  final int count;
}

class UploadNotSignedIn extends UploadOutcome {
  const UploadNotSignedIn();
}

class UploadFailure extends UploadOutcome {
  const UploadFailure({
    required this.message,
    this.detail,
    this.retryable = false,
  });
  final String message;
  final String? detail;

  /// True when the failure is plausibly transient (5xx, network) so the UI
  /// can offer a Retry button. False for permanent errors that need the
  /// user to do something (conflict, malformed, forbidden).
  final bool retryable;
}

/// Orchestrates the open-changeset / upload-diff / close-changeset sequence.
/// Stateless: a new instance per upload is fine.
class UploadService {
  UploadService([OsmApiService? api]) : _api = api ?? OsmApiService();

  final OsmApiService _api;

  Future<UploadOutcome> uploadAll({
    required List<PendingEdit> edits,
    required OsmAuthService authService,
    required EditQueueService editQueueService,
    required RecentUploadsService recentUploadsService,
    required SettingsService settingsService,
  }) async {
    if (edits.isEmpty) return const UploadSuccess(0);

    final accessToken = await authService.getValidAccessToken();
    if (accessToken == null) return const UploadNotSignedIn();

    // Capture once so the whole upload sequence hits one server even if
    // settings change mid-flight (which would also have signed us out, but
    // belt-and-suspenders).
    final baseUrl = settingsService.osmApiUrl;

    final tags = {
      'created_by': 'Swap Box Map 1.0',
      'comment': buildChangesetComment(edits),
    };

    int changesetId;
    try {
      changesetId = await _api.openChangeset(
        baseUrl: baseUrl,
        accessToken: accessToken,
        tags: tags,
      );
    } on OsmApiException catch (e) {
      return _toOutcome(e);
    } catch (e) {
      return UploadFailure(
        message: "Couldn't reach OpenStreetMap to open a changeset.",
        detail: e.toString(),
        retryable: true,
      );
    }

    final xml = buildOsmChange(changesetId: changesetId, edits: edits);

    List<DiffResultEntry> diffResult;
    try {
      diffResult = await _api.uploadDiff(
        baseUrl: baseUrl,
        accessToken: accessToken,
        changesetId: changesetId,
        osmChangeXml: xml,
      );
    } on OsmApiException catch (e) {
      // Best-effort close so we don't leave an open changeset on the user's
      // account; ignore failures because OSM auto-closes after ~1 hour.
      await _bestEffortClose(baseUrl, accessToken, changesetId);
      return _toOutcome(e);
    } catch (e) {
      await _bestEffortClose(baseUrl, accessToken, changesetId);
      return UploadFailure(
        message: "Couldn't upload edits to OpenStreetMap.",
        detail: e.toString(),
        retryable: true,
      );
    }

    await _bestEffortClose(baseUrl, accessToken, changesetId);
    await _persistCacheEntries(
      edits: edits,
      diffResult: diffResult,
      recentUploadsService: recentUploadsService,
    );
    await editQueueService.clear();
    return UploadSuccess(edits.length);
  }

  /// Translate each successfully-uploaded [PendingEdit] into a
  /// [RecentUpload] so the map can keep showing the post-upload state while
  /// Overpass catches up.
  Future<void> _persistCacheEntries({
    required List<PendingEdit> edits,
    required List<DiffResultEntry> diffResult,
    required RecentUploadsService recentUploadsService,
  }) async {
    final now = DateTime.now();
    final byOldId = <int, DiffResultEntry>{
      for (final e in diffResult) e.oldId: e,
    };
    final entries = <RecentUpload>[];

    // Creates are placeholder-keyed: -1, -2, ... matching the order
    // buildOsmChange iterated them.
    final creates = edits
        .where((e) => e.op == PendingEditOp.create)
        .toList(growable: false);
    for (var i = 0; i < creates.length; i++) {
      final create = creates[i];
      final placeholderId = -(i + 1);
      final diff = byOldId[placeholderId];
      final newId = diff?.newId;
      final lat = create.newLat;
      final lon = create.newLon;
      final tags = create.newTags;
      if (newId == null || lat == null || lon == null || tags == null) {
        continue;
      }
      entries.add(
        RecentUpload(
          osmId: newId,
          op: RecentUploadOp.create,
          version: diff?.newVersion ?? 1,
          lat: lat,
          lon: lon,
          tags: Map<String, String>.from(tags),
          uploadedAt: now,
        ),
      );
    }

    for (final modify in edits.where((e) => e.op == PendingEditOp.modify)) {
      final osmId = modify.osmId;
      final tags = modify.newTags;
      final lat = modify.newLat ?? modify.originalLat;
      final lon = modify.newLon ?? modify.originalLon;
      if (osmId == null || tags == null || lat == null || lon == null) {
        continue;
      }
      final diff = byOldId[osmId];
      entries.add(
        RecentUpload(
          osmId: osmId,
          op: RecentUploadOp.modify,
          version: diff?.newVersion ?? ((modify.baseVersion ?? 0) + 1),
          lat: lat,
          lon: lon,
          tags: Map<String, String>.from(tags),
          uploadedAt: now,
        ),
      );
    }

    for (final del in edits.where((e) => e.op == PendingEditOp.delete)) {
      final osmId = del.osmId;
      final lat = del.originalLat;
      final lon = del.originalLon;
      if (osmId == null || lat == null || lon == null) continue;
      final diff = byOldId[osmId];
      entries.add(
        RecentUpload(
          osmId: osmId,
          op: RecentUploadOp.delete,
          version: diff?.newVersion ?? ((del.baseVersion ?? 0) + 1),
          lat: lat,
          lon: lon,
          tags: null,
          uploadedAt: now,
        ),
      );
    }

    await recentUploadsService.storeAll(entries);
  }

  Future<void> _bestEffortClose(
    String baseUrl,
    String accessToken,
    int changesetId,
  ) async {
    try {
      await _api.closeChangeset(
        baseUrl: baseUrl,
        accessToken: accessToken,
        changesetId: changesetId,
      );
    } catch (_) {
      // Intentionally swallowed — OSM auto-closes idle changesets and a
      // failed close shouldn't mask a successful upload (or surface a second
      // error on a failed one).
    }
  }

  UploadOutcome _toOutcome(OsmApiException e) {
    final detail = 'HTTP ${e.statusCode}\n${e.body}';
    switch (e.statusCode) {
      // Session expired mid-upload is functionally the same as never having
      // been signed in — route both to the same branch so the UI offers a
      // single "Sign in" CTA.
      case 401:
        return const UploadNotSignedIn();
      case 403:
        return UploadFailure(
          message:
              "Your OpenStreetMap account isn't permitted to make this edit.",
          detail: detail,
        );
      case 409:
        return UploadFailure(
          message:
              'Some points have changed on OpenStreetMap since you edited them. Reload the map and try again.',
          detail: detail,
        );
      case 410:
        return UploadFailure(
          message:
              'A point you edited has already been deleted on OpenStreetMap.',
          detail: detail,
        );
      case 400:
        return UploadFailure(
          message: 'OpenStreetMap rejected the edits as malformed.',
          detail: detail,
        );
      default:
        if (e.statusCode >= 500) {
          return UploadFailure(
            message:
                'OpenStreetMap is having trouble right now. Try again later.',
            detail: detail,
            retryable: true,
          );
        }
        return UploadFailure(
          message: 'Upload failed (HTTP ${e.statusCode}).',
          detail: detail,
        );
    }
  }
}

/// Auto-generated changeset comment. Verb-led, type-aggregated, types within
/// each verb bucket are sorted by descending count (then alphabetically by
/// OSM amenity value for stable output).
String buildChangesetComment(List<PendingEdit> edits) {
  final added = <AmenityType, int>{};
  final verified = <AmenityType, int>{};
  final updated = <AmenityType, int>{};
  final removed = <AmenityType, int>{};

  for (final edit in edits) {
    final type = _typeOf(edit);
    if (type == null) continue;
    switch (edit.op) {
      case PendingEditOp.create:
        added[type] = (added[type] ?? 0) + 1;
      case PendingEditOp.delete:
        removed[type] = (removed[type] ?? 0) + 1;
      case PendingEditOp.modify:
        final k = edit.modifyKind;
        if (k.checked && !k.moved && !k.editedMetadata) {
          verified[type] = (verified[type] ?? 0) + 1;
        } else {
          updated[type] = (updated[type] ?? 0) + 1;
        }
    }
  }

  final clauses = <String>[];
  void addClause(String verb, Map<AmenityType, int> bucket) {
    if (bucket.isEmpty) return;
    clauses.add('$verb ${_phraseFor(bucket)}');
  }

  // Capitalize only the first verb; later verbs read as a comma-separated
  // continuation ("Added 2 …, verified 3 …, removed 1 …").
  addClause('Added', added);
  addClause(clauses.isEmpty ? 'Verified' : 'verified', verified);
  addClause(clauses.isEmpty ? 'Updated' : 'updated', updated);
  addClause(clauses.isEmpty ? 'Removed' : 'removed', removed);

  if (clauses.isEmpty) return 'Swap box edits #swapboxmap';
  return '${clauses.join(', ')} #swapboxmap';
}

String _phraseFor(Map<AmenityType, int> bucket) {
  final entries = bucket.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      if (byCount != 0) return byCount;
      return a.key.osmValue.compareTo(b.key.osmValue);
    });
  return entries.map((e) => '${e.value} ${_label(e.key, e.value)}').join(', ');
}

String _label(AmenityType type, int count) {
  final plural = count != 1;
  switch (type) {
    case AmenityType.foodSharing:
      return plural ? 'food sharing locations' : 'food sharing location';
    case AmenityType.publicBookcase:
      return plural ? 'public bookcases' : 'public bookcase';
    case AmenityType.giveBox:
      return plural ? 'give boxes' : 'give box';
  }
}

AmenityType? _typeOf(PendingEdit edit) {
  final tags = edit.newTags ?? edit.originalTags;
  if (tags == null) return null;
  var type = AmenityType.fromOsmValue(tags['amenity']);
  if (type == null) return null;
  if (type == AmenityType.foodSharing && tags['vending'] == 'pet_food') {
    type = AmenityType.giveBox;
  }
  return type;
}

/// Builds an osmChange XML document grouping the edits by op. Creates use
/// negative placeholder IDs (-1, -2, ...) which OSM resolves to real IDs in
/// the diffResult response.
String buildOsmChange({
  required int changesetId,
  required List<PendingEdit> edits,
}) {
  final creates = edits
      .where((e) => e.op == PendingEditOp.create)
      .toList(growable: false);
  final modifies = edits
      .where((e) => e.op == PendingEditOp.modify)
      .toList(growable: false);
  final deletes = edits
      .where((e) => e.op == PendingEditOp.delete)
      .toList(growable: false);

  final builder = XmlBuilder();
  builder.element(
    'osmChange',
    attributes: {'version': '0.6', 'generator': 'Swap Box Map 1.0'},
    nest: () {
      if (creates.isNotEmpty) {
        builder.element(
          'create',
          nest: () {
            var placeholderId = -1;
            for (final edit in creates) {
              _writeNode(
                builder,
                id: placeholderId,
                version: 0,
                changesetId: changesetId,
                lat: edit.newLat!,
                lon: edit.newLon!,
                tags: edit.newTags,
              );
              placeholderId -= 1;
            }
          },
        );
      }
      if (modifies.isNotEmpty) {
        builder.element(
          'modify',
          nest: () {
            for (final edit in modifies) {
              _writeNode(
                builder,
                id: edit.osmId!,
                version: edit.baseVersion ?? 0,
                changesetId: changesetId,
                lat: edit.newLat ?? edit.originalLat!,
                lon: edit.newLon ?? edit.originalLon!,
                tags: edit.newTags,
              );
            }
          },
        );
      }
      if (deletes.isNotEmpty) {
        builder.element(
          'delete',
          nest: () {
            for (final edit in deletes) {
              _writeNode(
                builder,
                id: edit.osmId!,
                version: edit.baseVersion ?? 0,
                changesetId: changesetId,
                lat: edit.originalLat!,
                lon: edit.originalLon!,
                tags: null,
              );
            }
          },
        );
      }
    },
  );
  return builder.buildDocument().toXmlString();
}

void _writeNode(
  XmlBuilder builder, {
  required int id,
  required int version,
  required int changesetId,
  required double lat,
  required double lon,
  required Map<String, String>? tags,
}) {
  builder.element(
    'node',
    attributes: {
      'id': '$id',
      'version': '$version',
      'changeset': '$changesetId',
      'lat': lat.toStringAsFixed(7),
      'lon': lon.toStringAsFixed(7),
    },
    nest: () {
      if (tags == null) return;
      for (final entry in tags.entries) {
        builder.element('tag', attributes: {'k': entry.key, 'v': entry.value});
      }
    },
  );
}
