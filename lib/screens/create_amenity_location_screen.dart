import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../config.dart';
import '../models/amenity.dart';
import '../models/pending_edit.dart';
import '../services/amenity_service.dart';
import '../services/edit_queue_service.dart';
import '../services/settings_service.dart';

/// Map-with-crosshair location picker. Pops a [LatLng] when the user
/// confirms (or null on Cancel). Used for both placing a brand-new POI and
/// for relocating an existing one from the edit form.
class CreateAmenityLocationScreen extends StatefulWidget {
  const CreateAmenityLocationScreen({
    super.key,
    required this.type,
    required this.settingsService,
    required this.editQueueService,
    required this.initialCenter,
    required this.initialZoom,
    required this.initialAmenities,
    this.title,
    this.actionLabel,
    this.previousLocation,
    this.excludeAmenityId,
    this.excludePendingCreateLocalId,
  });

  final AmenityType type;
  final SettingsService settingsService;
  final EditQueueService editQueueService;
  final LatLng initialCenter;
  final double initialZoom;

  /// Amenities already loaded on the home screen — pre-rendered so the user
  /// sees nearby existing POIs immediately. Filtered to [type] on init; the
  /// screen runs its own fetch on pan/zoom to extend coverage as needed.
  final List<Amenity> initialAmenities;

  /// AppBar title. Defaults to "Create &lt;type&gt;".
  final String? title;

  /// Bottom-button label. Defaults to "Choose Location".
  final String? actionLabel;

  /// When relocating an existing POI, the coordinates where that POI sits
  /// before this picker session. Rendered as a greyed circle so the user
  /// reads it as "this POI being moved", not a separate conflicting node.
  final LatLng? previousLocation;

  /// OSM node id of the POI being relocated. Suppressed in the regular
  /// amenity render so the POI only appears as the greyed ghost.
  final int? excludeAmenityId;

  /// PendingEdit.localId of the queued create being relocated. Same purpose
  /// as [excludeAmenityId] but for create entries.
  final String? excludePendingCreateLocalId;

  @override
  State<CreateAmenityLocationScreen> createState() =>
      _CreateAmenityLocationScreenState();
}

class _CreateAmenityLocationScreenState
    extends State<CreateAmenityLocationScreen> {
  static const double _fetchPaddingFactor = 1.0;
  static const double _minFetchZoom = AppConfig.minReadZoom;

  final AmenityService _amenityService = AmenityService();
  MapLibreMapController? _controller;
  Timer? _refreshDebounce;
  LatLngBounds? _coveredBounds;
  bool _fetching = false;
  bool _zoomedOut = false;
  List<Amenity> _amenities = const [];

  @override
  void initState() {
    super.initState();
    _amenities = widget.initialAmenities
        .where((a) => a.type == widget.type)
        .toList();
    widget.editQueueService.addListener(_onQueueChanged);
  }

  @override
  void dispose() {
    widget.editQueueService.removeListener(_onQueueChanged);
    _refreshDebounce?.cancel();
    super.dispose();
  }

  void _onQueueChanged() {
    if (_controller == null) return;
    _renderCircles();
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 400), _maybeRefresh);
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
    if (covered != null && _contains(covered, visible)) return;
    final fetchBounds = _expand(visible, _fetchPaddingFactor);
    setState(() => _fetching = true);
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
      _amenities = result.amenities
          .where((a) => a.type == widget.type)
          .toList();
      await _renderCircles();
    } catch (_) {
      // Soft-fail — the placement screen isn't load-bearing for fetching.
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  // Coalesce concurrent _renderCircles calls (queue change while a fetch is
  // finishing) so clearCircles/addCircle don't interleave. Mirrors the
  // pattern in HomeScreen.
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
    final color = _colorFor(widget.type);

    final pendingById = <int, PendingEdit>{};
    for (final edit in widget.editQueueService.pending) {
      if (edit.osmId == null) continue;
      if (edit.op == PendingEditOp.create) continue;
      pendingById[edit.osmId!] = edit;
    }

    for (final a in _amenities) {
      if (a.id == widget.excludeAmenityId) continue;
      final pending = pendingById[a.id];
      final lat = pending?.newLat ?? a.lat;
      final lon = pending?.newLon ?? a.lon;
      await controller.addCircle(
        CircleOptions(
          geometry: LatLng(lat, lon),
          circleColor: color,
          circleRadius: 8,
          circleStrokeWidth: pending != null ? 3 : 2,
          circleStrokeColor: pending != null ? '#ffd54f' : '#ffffff',
        ),
      );
    }

    for (final edit in widget.editQueueService.pending) {
      if (edit.op != PendingEditOp.create) continue;
      if (edit.localId == widget.excludePendingCreateLocalId) continue;
      final lat = edit.newLat;
      final lon = edit.newLon;
      final tags = edit.newTags;
      if (lat == null || lon == null || tags == null) continue;
      var type = AmenityType.fromOsmValue(tags['amenity']);
      if (type == null) continue;
      if (type == AmenityType.foodSharing && tags['vending'] == 'pet_food') {
        type = AmenityType.giveBox;
      }
      if (type != widget.type) continue;
      await controller.addCircle(
        CircleOptions(
          geometry: LatLng(lat, lon),
          circleColor: color,
          circleRadius: 8,
          circleStrokeWidth: 3,
          circleStrokeColor: '#ffd54f',
        ),
      );
    }

    final previous = widget.previousLocation;
    if (previous != null) {
      await controller.addCircle(
        CircleOptions(
          geometry: previous,
          circleColor: '#9e9e9e',
          circleRadius: 8,
          circleStrokeWidth: 2,
          circleStrokeColor: '#ffffff',
        ),
      );
    }
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

  void _chooseLocation() {
    final center = _controller?.cameraPosition?.target;
    if (center == null) return;
    Navigator.of(context).pop(center);
  }

  String _titleFor(AmenityType t) {
    switch (t) {
      case AmenityType.foodSharing:
        return 'Food Sharing';
      case AmenityType.publicBookcase:
        return 'Public Bookcase';
      case AmenityType.giveBox:
        return 'Give Box';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(widget.title ?? 'Create ${_titleFor(widget.type)}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.check),
              label: Text(widget.actionLabel ?? 'Choose Location'),
              onPressed: _chooseLocation,
            ),
          ),
        ),
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MapLibreMap(
            styleString: AppConfig.mapStyleUrl,
            initialCameraPosition: CameraPosition(
              target: widget.initialCenter,
              zoom: widget.initialZoom,
            ),
            trackCameraPosition: true,
            onMapCreated: (controller) => _controller = controller,
            onStyleLoadedCallback: () {
              _renderCircles();
              _maybeRefresh();
            },
            onCameraIdle: _scheduleRefresh,
          ),
          const IgnorePointer(child: _Crosshair()),
        ],
      ),
    );
  }
}

class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) {
    const color = Colors.black87;
    return SizedBox(
      width: 48,
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(width: 48, height: 2, color: color),
          Container(width: 2, height: 48, color: color),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}
