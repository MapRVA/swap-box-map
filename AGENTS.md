# AGENTS.md

## What this app is

"Swap Box Map" (Flutter Android/iOS; package name `swap_box_map`) is an OpenStreetMap editor focused on three node types: `amenity=food_sharing`, `amenity=public_bookcase`, and `amenity=give_box`. Users sign in with OSM, browse nearby POIs on a MapLibre basemap, queue create/modify/delete edits locally, and bulk-upload the queue as a single changeset.

Locked to portrait via `SystemChrome.setPreferredOrientations` in `main.dart`.

## Common commands

- `flutter pub get` — install deps after pulling or editing `pubspec.yaml`.
- `flutter run` — run on the connected device/emulator. Add `-d <id>` to target a specific one (`flutter devices`).
- `flutter analyze` — static analysis using `flutter_lints` (configured in `analysis_options.yaml`).
- `flutter test` — run the suite. Single file: `flutter test test/widget_test.dart`. Single test: `flutter test --plain-name "test name"`.
- `flutter build apk` / `flutter build ipa` — release artifacts.

Two `--dart-define` flags in `lib/config.dart` pick the backend: `USE_DEV_OSM_API` (defaults to `kDebugMode`, so `flutter run` hits the dev sandbox at `master.apis.dev.openstreetmap.org` and release builds hit production OSM) and `USE_OSM_API_FOR_READS` (defaults `false`; when `true`, bbox reads use `/api/0.6/map` on the OSM API instead of Overpass — required for round-tripping against the dev sandbox, which has no Overpass mirror). See README.md for the full matrix.

## Architecture

### Services as the source of truth

Four `ChangeNotifier` services are instantiated in `main.dart` and threaded down by constructor injection (no `Provider`/`Riverpod`). Each has an `isInitialized` flag and a `Future<void> init()` called once at app start; the root widget gates on all four before rendering past the loading spinner. `SettingsService.init()` is awaited synchronously in `main()` before the other services are constructed — `OsmAuthService` reads `settingsService.osmApiUrl` at construction time to build its OAuth helper.

- **`OsmAuthService`** — wraps `oauth2_client` with PKCE against the configured OSM server. Holds the token in `flutter_secure_storage` and the `OsmUser` in memory. `getValidAccessToken()` preflight-refreshes an expired token via the refresh grant before handing it back; callers don't retry on 401. On login it fire-and-forget primes `DefaultCacheManager` so the avatar lands in the on-disk cache used by `CachedNetworkImageProvider`. Listens to `SettingsService` and clears its session when `osmApiUrl` changes (tokens are bound to the issuing server).
- **`SettingsService`** — `shared_preferences` for user URL overrides (Overpass and OSM API). Falls back to `AppConfig.overpassUrl` / `AppConfig.osmBaseUrl`. The OSM API override is currently service-only — its Settings UI was temporarily removed.
- **`EditQueueService`** — `sqflite` database at `<docs>/swap_box_map.db`. Single table `pending_edits` keyed on `local_id` (UUID) with a **partial unique index on `osm_id WHERE osm_id IS NOT NULL`** so each existing node has at most one queued edit, while creates (osm_id NULL) are unconstrained. `enqueue` uses `ConflictAlgorithm.replace` so re-enqueueing with the same `local_id` overwrites in place — this is how "resume editing a queued create" updates the row instead of duplicating.
- **`RecentUploadsService`** — `sqflite` database at `<docs>/recent_uploads.db` (separate from the queue). Caches POIs we just uploaded so they don't disappear from the map during Overpass replication lag. Rows are pruned by `pruneInBbox(bounds, before:)` once Overpass's `osm3s.timestamp_osm_base` for the fetched bbox passes the row's `uploadedAt`. PK on `osm_id` + `ConflictAlgorithm.replace` so re-uploading a node overwrites its cache row in place.

Listeners drive UI: `HomeScreen` subscribes to `editQueueService` and re-renders map circles when anything changes. `AmenityDetailsSheet` wraps its content in a `ListenableBuilder` so the queue banner and "effective amenity" update without re-opening.

### The edit queue as a state model

`PendingEdit` (in `lib/models/pending_edit.dart`) is the single representation for queued mutations: `op` in `{create, modify, delete}`, plus `originalLat/Lon/Tags` (server state at edit start) and `newLat/Lon/Tags` (desired end state). For deletes, `new*` are null; for creates, `original*` and `osmId` are null. The `ModifyKind` getter classifies a modify into `{checked, moved, editedMetadata}` for UI labels.

The pattern "effective amenity" in `AmenityDetailsSheet` is important: when a `PendingEdit` exists for an amenity, the sheet renders an `Amenity` whose tags/lat/lon come from `pending.newTags ?? amenity.tags` (etc.). That way the user sees their queued edits without waiting for upload, including for moves.

### Map rendering and the pending-edit overlay

`HomeScreen._doRenderCircles` builds the on-map circle set from three sources:

1. **Effective amenity set** — fetched Overpass amenities merged with the `RecentUploadsService` cache: cache deletes suppress the Overpass row, cache modifies overlay it, cache creates that Overpass hasn't surfaced yet are appended. This bridges replication lag invisibly.
2. **Pending-edit overlay** — for each effective amenity, look up a queued modify/delete by `osmId`. If one exists, shift the circle to `pending.newLat/newLon` (so queued moves are visible) and switch the stroke to amber `#ffd54f` with width 3. This is the visual signal "you've edited this POI".
3. **Queued creates** — rendered separately at `edit.newLat/newLon` with the amber stroke. Apply the `food_sharing` + `vending=pet_food` → `giveBox` reclassification (see below) so they land in the right type bucket.

`CreateAmenityLocationScreen` runs a slimmer version of the same flow for the picker map.

Concurrent renders are coalesced via `_renderInProgress`/`_renderRequestedAgain`: while a render is awaiting `clearCircles`/`addCircle`, additional requests set a flag and the loop re-runs once after the current one completes. Without this, a fetch finishing while the queue changes leaves the map with an inconsistent circle set.

The synthetic `Amenity` used for a queued create has `id: 0` as a sentinel — `AmenityDetailsSheet` hides the "OSM node #…" row when it sees that. `_pendingCreateLocalIdByCircleId` maps the circle to its `PendingEdit.localId`, which the sheet uses (via the `pendingCreateLocalId` arg) to look up the queue entry by `localId` instead of `osmId`.

### The food_sharing ↔ giveBox reclassification

OSM uses `amenity=food_sharing` for pet-food sharing boxes (`vending=pet_food`), but UX-wise we want those in the give-box bucket. `Amenity.fromOverpassNode` performs this reclassification on load, and the rendering code in the home map and picker mirrors it for queued creates. Anywhere you derive `AmenityType` from raw tags, apply the same rule.

### Picker (location-selection map) reuse

`CreateAmenityLocationScreen` is dual-purpose: pops with a `LatLng` when the user confirms. It's used both for placing a brand-new POI (from the drawer's "+" buttons → `HomeScreen._startAddPoi`) and for relocating an existing POI (from `EditAmenityScreen._pickNewLocation` via the minimap tap). The two callers differ only in:

- `title`/`actionLabel` — defaults are "Create <Type>" / "Choose Location".
- `previousLocation` + `excludeAmenityId` or `excludePendingCreateLocalId` — set during a relocate to grey-ghost the POI's current location and prevent double-rendering it as a normal circle.

### Edit form (`EditAmenityScreen`) modes

Two named constructors:

- `.modify(amenity, ...)` — edits an existing OSM node. `_originalTags` snapshots server state (for conflict detection on upload); `_baselineTags` starts from a queued modify's `newTags` if any, so resuming an edit picks up where the user left off.
- `.create(initialType, initialLat, initialLon, ...)` — queues a brand-new node. Accepts optional `resumeFromLocalId` + `initialTags` to resume a queued create; `_save` reuses the same `localId` so the queue's `ConflictAlgorithm.replace` overwrites the row.

The "no changes" save guard checks **both** tag equality and `_baselineLat/_baselineLon != _currentLat/_currentLon`, so a move-only edit still enqueues. Lat/lon are stored in `_currentLat/_currentLon` and updated when the picker returns; the minimap's MapLibre camera is moved via the controller (since `initialCameraPosition` only fires on creation).

### Upload pipeline

`UploadService.uploadAll` (`lib/services/upload_service.dart`) drives the "Upload All" button on `EditQueueScreen`:

1. Fetch a fresh access token via `OsmAuthService.getValidAccessToken()` (preflight refresh; no retry on 401).
2. `OsmApiService.openChangeset` → `PUT /api/0.6/changeset/create` with an auto-generated comment from `buildChangesetComment` (verb-led, type-aggregated, e.g. `"Added 2 give boxes, verified 1 public bookcase #swapboxmap"`).
3. `OsmApiService.uploadDiff` → `POST /api/0.6/changeset/<id>/upload` with an `osmChange` payload built via the `xml` package; creates use negative placeholder IDs that the server rewrites in the returned `diffResult`.
4. `OsmApiService.closeChangeset` → `PUT /api/0.6/changeset/<id>/close`.

Stops on the first `OsmApiException`; the queue is left intact and a typed `UploadOutcome` (`UploadSuccess` / `UploadNotSignedIn` / `UploadFailure { retryable }`) bubbles up so the UI can offer Retry, a sign-in prompt, or a hard error dialog. On success, uploaded `PendingEdit`s are removed from `EditQueueService` and their server-assigned ids/versions are written into `RecentUploadsService` to bridge Overpass replication lag.

## Conventions worth knowing

- The MapLibre style URL and Overpass URL live in `AppConfig` (`lib/config.dart`). Don't duplicate them in screens.
- Material 3, single seed color (`Colors.green`). Type colors are hand-picked hex constants (`#2e7d32` food, `#1565c0` bookcase, `#ef6c00` give-box) and are duplicated across `HomeScreen`, `CreateAmenityLocationScreen`, and `AmenityDetailsSheet` — keep them in sync.
- `Scaffold.resizeToAvoidBottomInset: false` is set on `HomeScreen` because popping back from the edit screen while the soft keyboard is still receding would otherwise resize the map and visibly stretch the GL view.
- `FocusScope.of(context).unfocus()` is called at the top of `_save`/`_delete` in `EditAmenityScreen` to avoid the same keyboard-inset race on the popping route.

## OAuth wiring

Native sides must handle the `swapboxmap://oauth2/redirect` custom URI scheme. The Android manifest declares the intent filter; iOS `Info.plist` declares `CFBundleURLSchemes`.

OSM issues client IDs per-server: `AppConfig._devOsmClientId` is populated for the dev sandbox; `_prodOsmClientId` is a `REGISTER_AT_PROD_AND_PASTE_HERE` placeholder. Register at `https://www.openstreetmap.org/oauth2/applications` (native/public client, scopes `read_prefs` + `write_api`) and paste before shipping a release. `AppConfig.osmClientId` switches between the two based on `USE_DEV_OSM_API`.
