import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/amenity.dart';
import '../models/pending_edit.dart';
import '../models/recent_upload.dart';
import '../services/amenity_service.dart';
import '../services/edit_queue_service.dart';
import '../services/osm_auth_service.dart';
import '../services/recent_uploads_service.dart';
import '../services/settings_service.dart';
import '../widgets/amenity_details_sheet.dart';
import 'create_amenity_location_screen.dart';
import 'edit_amenity_screen.dart';
import 'edit_queue_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.authService,
    required this.settingsService,
    required this.editQueueService,
    required this.recentUploadsService,
  });

  final OsmAuthService authService;
  final SettingsService settingsService;
  final EditQueueService editQueueService;
  final RecentUploadsService recentUploadsService;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // Richmond, VA — the "RVA" in the maprva org name.
  static const LatLng _initialCenter = LatLng(37.5407, -77.4360);

  // When we fetch, we grab a bbox this many times larger (linear) than what's
  // visible, centered on the current view. The fetched area is therefore ~9x
  // the screen, so panning anywhere inside it doesn't re-trigger a fetch.
  static const double _fetchPaddingFactor = 1.0;

  // Below this zoom the fetch bbox is too large; we skip fetching and
  // prompt the user to zoom in. Threshold depends on the read backend —
  // OSM API caps bbox area at 0.25 sq-deg; Overpass has no such cap.
  static const double _minFetchZoom = AppConfig.minReadZoom;

  // If the user revisits an area they last fetched longer than this ago, treat
  // the cached bounds as stale and refetch — so edits made on OSM since the
  // initial load eventually show up without restarting the app.
  static const Duration _cacheTtl = Duration(hours: 1);

  // Has to match the bottom sheet's initialChildSize in AmenityDetailsSheet —
  // used to compute the camera offset that keeps the POI visible above it.
  static const double _sheetInitialFraction = 0.45;

  final AmenityService _amenityService = AmenityService();
  MapLibreMapController? _controller;
  Timer? _refreshDebounce;
  LatLngBounds? _coveredBounds;
  DateTime? _coveredAt;
  bool _fetching = false;
  String? _lastError;
  bool _zoomedOut = false;
  bool _myLocationEnabled = false;
  bool _locating = false;
  // True once we observe LocationPermission.deniedForever — the locate-me
  // FAB is hidden in that state, since tapping it would just snackbar an
  // error. Re-checked on app resume so the FAB reappears if the user grants
  // permission via the system settings screen.
  bool _locationPermanentlyDenied = false;
  // Cached the last time the locate-me FAB ran. Passed to the POI sheet so it
  // can gate the Verify button on physical proximity — only set when the user
  // has explicitly asked for their location, mirroring MapLibre's dot state.
  Position? _userPosition;
  final Map<String, Amenity> _amenityByCircleId = {};
  // Tracks which circles correspond to a queued create (by PendingEdit.localId)
  // so taps on them can pass the localId to the details sheet for lookup.
  final Map<String, String> _pendingCreateLocalIdByCircleId = {};
  List<Amenity> _amenities = const [];
  final Set<AmenityType> _enabledTypes = {...AmenityType.values};

  String _lastOverpassUrl = '';

  @override
  void initState() {
    super.initState();
    _lastOverpassUrl = widget.settingsService.overpassUrl;
    widget.settingsService.addListener(_onSettingsChanged);
    widget.editQueueService.addListener(_onQueueChanged);
    widget.recentUploadsService.addListener(_onRecentUploadsChanged);
    WidgetsBinding.instance.addObserver(this);
    _refreshLocationPermissionState();
  }

  @override
  void dispose() {
    widget.settingsService.removeListener(_onSettingsChanged);
    widget.editQueueService.removeListener(_onQueueChanged);
    widget.recentUploadsService.removeListener(_onRecentUploadsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _refreshDebounce?.cancel();
    super.dispose();
  }

  void _onQueueChanged() {
    if (_controller == null) return;
    _renderCircles();
  }

  void _onRecentUploadsChanged() {
    if (_controller == null) return;
    _renderCircles();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshLocationPermissionState();
    }
  }

  Future<void> _refreshLocationPermissionState() async {
    try {
      final permission = await Geolocator.checkPermission();
      if (!mounted) return;
      final denied = permission == LocationPermission.deniedForever;
      if (denied != _locationPermanentlyDenied) {
        setState(() => _locationPermanentlyDenied = denied);
      }
    } catch (_) {
      // Best-effort — leave the FAB visible if the lookup fails.
    }
  }

  void _onSettingsChanged() {
    final current = widget.settingsService.overpassUrl;
    if (current == _lastOverpassUrl) return;
    _lastOverpassUrl = current;
    // Endpoint changed — drop the cached bounds and refetch.
    _coveredBounds = null;
    _coveredAt = null;
    _amenities = const [];
    _maybeRefresh();
  }

  Future<void> _maybeRefresh() async {
    final controller = _controller;
    if (controller == null || _fetching) return;
    final zoom = controller.cameraPosition?.zoom ?? 0;
    if (zoom < _minFetchZoom) {
      if (!_zoomedOut) setState(() => _zoomedOut = true);
      return;
    }
    if (_zoomedOut) setState(() => _zoomedOut = false);
    final visible = await controller.getVisibleRegion();
    final covered = _coveredBounds;
    final coveredAt = _coveredAt;
    final fresh =
        coveredAt != null && DateTime.now().difference(coveredAt) < _cacheTtl;
    if (covered != null && fresh && _contains(covered, visible)) return;
    final fetchBounds = _expand(visible, _fetchPaddingFactor);
    setState(() {
      _fetching = true;
      _lastError = null;
    });
    try {
      final result = await _amenityService.fetchInBbox(
        south: fetchBounds.southwest.latitude,
        west: fetchBounds.southwest.longitude,
        north: fetchBounds.northeast.latitude,
        east: fetchBounds.northeast.longitude,
        overpassUrl: widget.settingsService.overpassUrl,
        osmApiUrl: widget.settingsService.osmApiUrl,
      );
      _coveredBounds = fetchBounds;
      _coveredAt = DateTime.now();
      _amenities = result.amenities;
      // Prune cache entries Overpass has now caught up to, scoped to the
      // region we just fetched.
      final timestamp = result.osmBaseTimestamp;
      if (timestamp != null) {
        await widget.recentUploadsService.pruneInBbox(
          bounds: fetchBounds,
          before: timestamp,
        );
      }
      await _renderCircles();
    } catch (e) {
      debugPrint('Amenity refresh failed: $e');
      if (mounted) setState(() => _lastError = e.toString());
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  // Concurrent _renderCircles calls (fetch finishing while the queue
  // changes) interleave clearCircles/addCircle and corrupt the map. We
  // serialize: while a render is in progress, mark that another should run
  // afterward, and coalesce all pending requests into a single re-render.
  bool _renderInProgress = false;
  bool _renderRequestedAgain = false;

  Future<void> _renderCircles() async {
    if (_renderInProgress) {
      _renderRequestedAgain = true;
      return;
    }
    _renderInProgress = true;
    try {
      do {
        _renderRequestedAgain = false;
        await _doRenderCircles();
      } while (_renderRequestedAgain && mounted);
    } finally {
      _renderInProgress = false;
    }
  }

  Future<void> _doRenderCircles() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.clearCircles();
    _amenityByCircleId.clear();
    _pendingCreateLocalIdByCircleId.clear();
    // Index any pending edit that targets an existing node (modify or
    // delete). All of them get the amber-stroke "pending" highlight so the
    // user can see at a glance which POIs they've touched. Modifies with a
    // queued move also shift the circle to the new coords.
    final pendingById = <int, PendingEdit>{};
    for (final edit in widget.editQueueService.pending) {
      if (edit.osmId == null) continue;
      if (edit.op == PendingEditOp.create) continue;
      pendingById[edit.osmId!] = edit;
    }
    // Index recently-uploaded entries. Post-upload, pre-Overpass-catchup:
    // these look like normal POIs on the map; the cache bridges replication
    // lag. Pruned by [_maybeRefresh] once Overpass's timestamp passes.
    final cachedById = <int, RecentUpload>{
      for (final u in widget.recentUploadsService.all) u.osmId: u,
    };
    // Build the effective amenity set: cache deletes suppress; cache
    // modifies overlay; cache creates Overpass hasn't seen yet are added.
    final effective = <Amenity>[];
    for (final a in _amenities) {
      final cached = cachedById[a.id];
      if (cached == null) {
        effective.add(a);
        continue;
      }
      switch (cached.op) {
        case RecentUploadOp.delete:
          continue;
        case RecentUploadOp.create:
        case RecentUploadOp.modify:
          final overlay = _amenityFromCached(cached);
          effective.add(overlay ?? a);
      }
    }
    // Add cached entries that Overpass hasn't surfaced yet — both creates
    // (the node never existed there) and modifies (e.g., user edited a
    // freshly-uploaded create before Overpass replicated it; the cache row
    // is now op=modify-via-UPSERT and would otherwise be orphaned). Deletes
    // never get re-added — there's nothing to render.
    final overpassIds = {for (final a in _amenities) a.id};
    for (final u in widget.recentUploadsService.all) {
      if (u.op == RecentUploadOp.delete) continue;
      if (overpassIds.contains(u.osmId)) continue;
      final synth = _amenityFromCached(u);
      if (synth != null) effective.add(synth);
    }
    for (final a in effective) {
      if (!_enabledTypes.contains(a.type)) continue;
      final pending = pendingById[a.id];
      final lat = pending?.newLat ?? a.lat;
      final lon = pending?.newLon ?? a.lon;
      final circle = await controller.addCircle(
        CircleOptions(
          geometry: LatLng(lat, lon),
          circleColor: _colorFor(a.type),
          circleRadius: 8,
          circleStrokeWidth: pending != null ? 3 : 2,
          circleStrokeColor: pending != null ? '#ffd54f' : '#ffffff',
        ),
      );
      _amenityByCircleId[circle.id] = a;
    }
    // Queued creates haven't been uploaded yet — render them in the same
    // type color but with an amber stroke so they read as "yours, pending".
    for (final edit in widget.editQueueService.pending) {
      if (edit.op != PendingEditOp.create) continue;
      final lat = edit.newLat;
      final lon = edit.newLon;
      final tags = edit.newTags;
      if (lat == null || lon == null || tags == null) continue;
      var type = AmenityType.fromOsmValue(tags['amenity']);
      if (type == null) continue;
      if (type == AmenityType.foodSharing && tags['vending'] == 'pet_food') {
        type = AmenityType.giveBox;
      }
      if (!_enabledTypes.contains(type)) continue;
      final circle = await controller.addCircle(
        CircleOptions(
          geometry: LatLng(lat, lon),
          circleColor: _colorFor(type),
          circleRadius: 8,
          circleStrokeWidth: 3,
          circleStrokeColor: '#ffd54f',
        ),
      );
      // id == 0 is the sentinel for "no OSM id yet"; the sheet uses
      // pendingCreateLocalId to find the queue entry instead.
      _amenityByCircleId[circle.id] = Amenity(
        id: 0,
        type: type,
        lat: lat,
        lon: lon,
        tags: Map<String, String>.from(tags),
      );
      _pendingCreateLocalIdByCircleId[circle.id] = edit.localId;
    }
  }

  void _toggleType(AmenityType type, bool enabled) {
    setState(() {
      if (enabled) {
        _enabledTypes.add(type);
      } else {
        _enabledTypes.remove(type);
      }
    });
    _renderCircles();
  }

  Widget _buildStatusPill() {
    final theme = Theme.of(context);
    if (_fetching) {
      return Material(
        key: const ValueKey('loading'),
        elevation: 2,
        borderRadius: BorderRadius.circular(20),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('Loading…'),
            ],
          ),
        ),
      );
    }
    if (_zoomedOut) {
      return Material(
        key: const ValueKey('zoomed-out'),
        elevation: 2,
        borderRadius: BorderRadius.circular(20),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.zoom_in, size: 16),
              SizedBox(width: 8),
              Text('Zoom in to load more'),
            ],
          ),
        ),
      );
    }
    final error = _lastError;
    if (error != null) {
      return Material(
        key: const ValueKey('error'),
        elevation: 2,
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _showErrorDialog(error),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 16,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      "Couldn't load amenities — tap for details",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink(key: ValueKey('idle'));
  }

  void _showErrorDialog(String error) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Couldn't load amenities"),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: SingleChildScrollView(child: SelectableText(error)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                setState(() => _lastError = null);
                _maybeRefresh();
              },
              child: const Text('Retry'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _locateMe() async {
    if (_locating) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Location services are off. Enable them in settings.',
            ),
          ),
        );
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        if (permission == LocationPermission.deniedForever &&
            !_locationPermanentlyDenied) {
          setState(() => _locationPermanentlyDenied = true);
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              permission == LocationPermission.deniedForever
                  ? 'Location permission was permanently denied. Enable it in your app settings.'
                  : 'Location permission denied.',
            ),
          ),
        );
        return;
      }

      if (!_myLocationEnabled) {
        setState(() => _myLocationEnabled = true);
      }

      try {
        final pos = await Geolocator.getCurrentPosition();
        if (!mounted) return;
        setState(() => _userPosition = pos);
        final controller = _controller;
        if (controller == null) return;
        await controller.animateCamera(
          CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
        );
      } catch (e) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text("Couldn't get current location: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _startAddPoi(AmenityType type) async {
    Navigator.of(context).pop();
    final camera = _controller?.cameraPosition;
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute<LatLng>(
        builder: (_) => CreateAmenityLocationScreen(
          type: type,
          settingsService: widget.settingsService,
          editQueueService: widget.editQueueService,
          initialCenter: camera?.target ?? _initialCenter,
          initialZoom: camera?.zoom ?? 12,
          initialAmenities: _amenities,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => EditAmenityScreen.create(
          initialType: type,
          initialLat: picked.latitude,
          initialLon: picked.longitude,
          editQueueService: widget.editQueueService,
          settingsService: widget.settingsService,
        ),
      ),
    );
  }

  Future<void> _signIn() async {
    try {
      await widget.authService.signIn();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Sign-in failed: $e')));
    }
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), _maybeRefresh);
  }

  void _onCircleTapped(Circle circle) {
    final amenity = _amenityByCircleId[circle.id];
    if (amenity == null) return;
    _showAmenitySheet(
      amenity,
      pendingCreateLocalId: _pendingCreateLocalIdByCircleId[circle.id],
    );
  }

  void _showAmenitySheet(Amenity amenity, {String? pendingCreateLocalId}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) => AmenityDetailsSheet(
        amenity: amenity,
        authService: widget.authService,
        editQueueService: widget.editQueueService,
        settingsService: widget.settingsService,
        userPosition: _userPosition,
        pendingCreateLocalId: pendingCreateLocalId,
      ),
    );
  }

  /// Resolve a queued edit back to an Amenity for display. Prefers a
  /// currently-loaded amenity (so metadata like `lastEditedAt` is fresh) and
  /// falls back to reconstructing from the queued snapshot.
  Amenity? _amenityForEdit(PendingEdit edit) {
    if (edit.osmId == null) return null;
    for (final a in _amenities) {
      if (a.id == edit.osmId) return a;
    }
    final tags = edit.originalTags;
    final lat = edit.originalLat;
    final lon = edit.originalLon;
    if (tags == null || lat == null || lon == null) return null;
    var type = AmenityType.fromOsmValue(tags['amenity']);
    if (type == null) return null;
    // Mirror the foodSharing→giveBox reclassification we do in
    // `fromOverpassNode` so display is consistent.
    if (type == AmenityType.foodSharing && tags['vending'] == 'pet_food') {
      type = AmenityType.giveBox;
    }
    return Amenity(
      id: edit.osmId!,
      type: type,
      lat: lat,
      lon: lon,
      tags: tags,
      version: edit.baseVersion,
    );
  }

  Future<void> _onUploadedFromQueue(int count) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Uploaded $count ${count == 1 ? 'edit' : 'edits'}.'),
      ),
    );
    // No cache invalidation: the recent-uploads cache fills the gap until
    // Overpass replication catches up, and the normal TTL/idle-tick cadence
    // takes over from there.
  }

  /// Build an Amenity from a cache row, mirroring the food_sharing+pet_food
  /// → giveBox reclassification we apply everywhere else.
  static Amenity? _amenityFromCached(RecentUpload upload) {
    final tags = upload.tags;
    if (tags == null) return null;
    var type = AmenityType.fromOsmValue(tags['amenity']);
    if (type == null) return null;
    if (type == AmenityType.foodSharing && tags['vending'] == 'pet_food') {
      type = AmenityType.giveBox;
    }
    return Amenity(
      id: upload.osmId,
      type: type,
      lat: upload.lat,
      lon: upload.lon,
      tags: tags,
      version: upload.version,
      lastEditedAt: upload.uploadedAt,
    );
  }

  Future<void> _openQueuedEdit(PendingEdit edit) async {
    final amenity = _amenityForEdit(edit);
    if (amenity == null) return;
    final controller = _controller;
    if (controller != null) {
      // Center on the queued new position if the edit moved the node,
      // otherwise on the original — either way it's where the user expects
      // to see the marker after upload.
      final lat = edit.newLat ?? amenity.lat;
      final lon = edit.newLon ?? amenity.lon;
      // Snap (no animation) so we don't get a partway glide that the second
      // step interrupts. POI is centered first, then offset so it lands in
      // the middle of the visible (un-covered) band above the sheet.
      await controller.moveCamera(
        CameraUpdate.newLatLngZoom(LatLng(lat, lon), 16),
      );
      if (!mounted) return;
      final mediaHeight = MediaQuery.of(context).size.height;
      final visibleHeight = mediaHeight * (1 - _sheetInitialFraction);
      final desiredY = visibleHeight / 2;
      final shiftPixels = mediaHeight / 2 - desiredY;
      // scrollBy(0, +y) pans the camera north (POI moves down on screen);
      // we want the opposite, so push the negative offset.
      await controller.moveCamera(CameraUpdate.scrollBy(0, -shiftPixels));
    }
    if (!mounted) return;
    _showAmenitySheet(amenity);
  }

  static bool _contains(LatLngBounds outer, LatLngBounds inner) {
    return outer.southwest.latitude <= inner.southwest.latitude &&
        outer.southwest.longitude <= inner.southwest.longitude &&
        outer.northeast.latitude >= inner.northeast.latitude &&
        outer.northeast.longitude >= inner.northeast.longitude;
  }

  static LatLngBounds _expand(LatLngBounds b, double factor) {
    final dLat = (b.northeast.latitude - b.southwest.latitude) * factor;
    final dLon = (b.northeast.longitude - b.southwest.longitude) * factor;
    return LatLngBounds(
      southwest: LatLng(
        b.southwest.latitude - dLat,
        b.southwest.longitude - dLon,
      ),
      northeast: LatLng(
        b.northeast.latitude + dLat,
        b.northeast.longitude + dLon,
      ),
    );
  }

  static String _colorFor(AmenityType t) {
    switch (t) {
      case AmenityType.foodSharing:
        return '#2e7d32';
      case AmenityType.publicBookcase:
        return '#1565c0';
      case AmenityType.giveBox:
        return '#ef6c00';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // HomeScreen has no text inputs of its own; opting out of keyboard
      // insets prevents a brief map resize when popping back from the edit
      // screen while the soft keyboard is still receding.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('Swap Box Map'),
        actions: [
          ListenableBuilder(
            listenable: widget.editQueueService,
            builder: (context, _) {
              final count = widget.editQueueService.length;
              if (count == 0) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'Pending edits',
                icon: Badge(
                  label: Text('$count'),
                  child: const Icon(Icons.edit_note),
                ),
                onPressed: () async {
                  final result = await Navigator.of(context)
                      .push<EditQueueResult>(
                        MaterialPageRoute<EditQueueResult>(
                          builder: (_) => EditQueueScreen(
                            editQueueService: widget.editQueueService,
                            authService: widget.authService,
                            recentUploadsService: widget.recentUploadsService,
                            settingsService: widget.settingsService,
                          ),
                        ),
                      );
                  if (!mounted) return;
                  switch (result) {
                    case EditQueueOpenEdit(:final edit):
                      await _openQueuedEdit(edit);
                    case EditQueueUploaded(:final count):
                      await _onUploadedFromQueue(count);
                    case null:
                      break;
                  }
                },
              );
            },
          ),
          // Once `actions` is non-empty, AppBar stops auto-injecting the
          // endDrawer hamburger — so add it back explicitly.
          const EndDrawerButton(),
        ],
      ),
      endDrawer: ListenableBuilder(
        listenable: widget.authService,
        builder: (context, _) => _AppDrawer(
          authService: widget.authService,
          settingsService: widget.settingsService,
          enabledTypes: _enabledTypes,
          onToggleType: _toggleType,
          onAddType: _startAddPoi,
          onSignIn: _signIn,
        ),
      ),
      floatingActionButton: _locationPermanentlyDenied
          ? null
          : FloatingActionButton(
              onPressed: _locating ? null : _locateMe,
              tooltip: 'My location',
              child: _locating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _myLocationEnabled
                          ? Icons.my_location
                          : Icons.location_searching,
                    ),
            ),
      body: Stack(
        children: [
          MapLibreMap(
            styleString: AppConfig.mapStyleUrl,
            initialCameraPosition: const CameraPosition(
              target: _initialCenter,
              zoom: 12,
            ),
            trackCameraPosition: true,
            myLocationEnabled: _myLocationEnabled,
            onMapCreated: (controller) {
              _controller = controller;
              controller.onCircleTapped.add(_onCircleTapped);
            },
            onStyleLoadedCallback: _maybeRefresh,
            onCameraIdle: _scheduleRefresh,
          ),
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _buildStatusPill(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.authService,
    required this.settingsService,
    required this.enabledTypes,
    required this.onToggleType,
    required this.onAddType,
    required this.onSignIn,
  });

  final OsmAuthService authService;
  final SettingsService settingsService;
  final Set<AmenityType> enabledTypes;
  final void Function(AmenityType type, bool enabled) onToggleType;
  final void Function(AmenityType type) onAddType;
  final VoidCallback onSignIn;

  Future<void> _openProfile(String displayName) async {
    final uri = Uri.parse(
      '${AppConfig.osmBaseUrl}/user/${Uri.encodeComponent(displayName)}',
    );
    await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = authService.currentUser;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            if (user != null)
              UserAccountsDrawerHeader(
                decoration: BoxDecoration(color: theme.colorScheme.primary),
                currentAccountPicture: CircleAvatar(
                  backgroundImage: user.imageUrl != null
                      ? CachedNetworkImageProvider(user.imageUrl!)
                      : null,
                  child: user.imageUrl == null
                      ? const Icon(Icons.person)
                      : null,
                ),
                accountName: InkWell(
                  onTap: () => _openProfile(user.displayName),
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(user.displayName),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.open_in_new,
                        size: 14,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ],
                  ),
                ),
                accountEmail: const SizedBox.shrink(),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      onPressed: onSignIn,
                      icon: const Icon(Icons.login),
                      label: const Text('Sign in with OpenStreetMap'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in to create and edit points on the map.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Filter by type',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            _FilterTile(
              color: const Color(0xFF2E7D32),
              label: 'Food',
              enabled: enabledTypes.contains(AmenityType.foodSharing),
              onChanged: (v) => onToggleType(AmenityType.foodSharing, v),
              onAdd: () => onAddType(AmenityType.foodSharing),
            ),
            _FilterTile(
              color: const Color(0xFF1565C0),
              label: 'Public Bookcases',
              enabled: enabledTypes.contains(AmenityType.publicBookcase),
              onChanged: (v) => onToggleType(AmenityType.publicBookcase, v),
              onAdd: () => onAddType(AmenityType.publicBookcase),
            ),
            _FilterTile(
              color: const Color(0xFFEF6C00),
              label: 'Other Give Boxes',
              enabled: enabledTypes.contains(AmenityType.giveBox),
              onChanged: (v) => onToggleType(AmenityType.giveBox, v),
              onAdd: () => onAddType(AmenityType.giveBox),
            ),
            const Spacer(),
            const Divider(height: 0),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SettingsScreen(settingsService: settingsService),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.favorite_outline),
              title: const Text('Built by MapRVA'),
              trailing: const Icon(Icons.open_in_new, size: 16),
              onTap: () => launchUrl(Uri.parse('https://maprva.org')),
            ),
            if (user != null)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: () {
                  Navigator.of(context).pop();
                  authService.signOut();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _FilterTile extends StatelessWidget {
  const _FilterTile({
    required this.color,
    required this.label,
    required this.enabled,
    required this.onChanged,
    required this.onAdd,
  });

  final Color color;
  final String label;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      value: enabled,
      onChanged: (v) => onChanged(v ?? false),
      controlAffinity: ListTileControlAffinity.leading,
      title: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
      secondary: IconButton(
        icon: const Icon(Icons.add_location_alt_outlined),
        tooltip: 'Add a $label point',
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? onAdd : null,
      ),
    );
  }
}
