import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../models/amenity.dart';
import '../models/pending_edit.dart';
import '../services/edit_queue_service.dart';
import '../services/settings_service.dart';
import 'create_amenity_location_screen.dart';

const _lflBrand = 'Little Free Library';
const _lflWikidata = 'Q6650101';
const _knownBrands = <String>{_lflBrand};

String _snakeToTitleCase(String value) => value
    .split('_')
    .where((w) => w.isNotEmpty)
    .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

String _isoDate(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-'
    '${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')}';

String _nameFieldLabel(AmenityType type) {
  switch (type) {
    case AmenityType.publicBookcase:
      return 'Does this bookcase have a name?';
    case AmenityType.foodSharing:
      return 'Does this place have a name?';
    case AmenityType.giveBox:
      return 'Does this give box have a name?';
  }
}

String _websiteFieldLabel(AmenityType type) {
  switch (type) {
    case AmenityType.publicBookcase:
      return 'Website for this specific bookcase';
    case AmenityType.foodSharing:
      return 'Website for this specific place';
    case AmenityType.giveBox:
      return 'Website for this specific give box';
  }
}

String _typeTitle(AmenityType type) {
  switch (type) {
    case AmenityType.foodSharing:
      return 'Food Sharing';
    case AmenityType.publicBookcase:
      return 'Public Bookcase';
    case AmenityType.giveBox:
      return 'Give Box';
  }
}

class EditAmenityScreen extends StatefulWidget {
  /// Edit an existing OSM node.
  const EditAmenityScreen.modify({
    super.key,
    required Amenity this.amenity,
    required this.editQueueService,
    required this.settingsService,
  }) : initialType = null,
       initialLat = null,
       initialLon = null,
       resumeFromLocalId = null,
       initialTags = null;

  /// Queue a brand-new node of [initialType] at the given coordinates.
  /// Pass [resumeFromLocalId] + [initialTags] to resume editing an existing
  /// queued create — saving will overwrite that queue row instead of adding
  /// a duplicate.
  const EditAmenityScreen.create({
    super.key,
    required AmenityType this.initialType,
    required double this.initialLat,
    required double this.initialLon,
    required this.editQueueService,
    required this.settingsService,
    this.resumeFromLocalId,
    this.initialTags,
  }) : amenity = null;

  final Amenity? amenity;
  final AmenityType? initialType;
  final double? initialLat;
  final double? initialLon;
  final EditQueueService editQueueService;
  final SettingsService settingsService;
  final String? resumeFromLocalId;
  final Map<String, String>? initialTags;

  bool get isCreate => amenity == null;
  AmenityType get type => amenity?.type ?? initialType!;
  double get lat => amenity?.lat ?? initialLat!;
  double get lon => amenity?.lon ?? initialLon!;

  @override
  State<EditAmenityScreen> createState() => _EditAmenityScreenState();
}

class _EditAmenityScreenState extends State<EditAmenityScreen> {
  // The true server-side tags — preserved as PendingEdit.originalTags so the
  // upload can still detect conflicts even after several edit passes. Null in
  // create mode (there's no server-side state yet).
  late final Map<String, String>? _originalTags;

  // What the form is initialized from: queued state if a modify is already
  // pending, otherwise server tags. Saving compares against this to decide
  // whether anything changed in this pass.
  late final Map<String, String> _baselineTags;

  // Common controllers.
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _housenumber;
  late final TextEditingController _street;
  late final TextEditingController _operator;
  late final TextEditingController _operatorWebsite;
  late final TextEditingController _website;

  // OSM has both `website` and `contact:website`. Edit whichever key the
  // node already uses; default to the non-namespaced one.
  late final String _websiteKey;

  // Public-bookcase state.
  String? _bookcaseType;
  String? _brand;

  // Food-sharing state.
  bool _isFridge = false;

  // Give-box state. One of: mixed, clothes, shoes, art, puzzles.
  String _giveBoxKind = 'mixed';

  // Controls the bottom checkbox. When true, saving bumps check_date to
  // today. Defaults off — the Verify button on the POI sheet is the primary
  // way to bump check_date, so the edit form shouldn't do it implicitly.
  bool _updateCheckDate = false;

  // Current coordinates for the POI being edited/created. Initialized from
  // widget.lat/lon and updated when the user taps the minimap to relocate.
  late double _currentLat;
  late double _currentLon;
  // Coordinates at the moment editing started — used to detect whether the
  // user moved the POI, so a move-only edit doesn't slip past the no-changes
  // guard.
  late double _baselineLat;
  late double _baselineLon;
  MapLibreMapController? _minimapController;

  @override
  void initState() {
    super.initState();
    if (widget.isCreate) {
      _originalTags = null;
      _baselineTags = widget.initialTags != null
          ? Map<String, String>.from(widget.initialTags!)
          : <String, String>{'amenity': widget.type.osmValue};
      _currentLat = widget.lat;
      _currentLon = widget.lon;
    } else {
      final pending = _findPendingModify();
      _originalTags = pending?.originalTags != null
          ? Map<String, String>.from(pending!.originalTags!)
          : Map<String, String>.from(widget.amenity!.tags);
      _baselineTags = pending?.newTags != null
          ? Map<String, String>.from(pending!.newTags!)
          : Map<String, String>.from(widget.amenity!.tags);
      _currentLat = pending?.newLat ?? widget.amenity!.lat;
      _currentLon = pending?.newLon ?? widget.amenity!.lon;
    }
    _baselineLat = _currentLat;
    _baselineLon = _currentLon;

    _websiteKey =
        _baselineTags.containsKey('contact:website') &&
            !_baselineTags.containsKey('website')
        ? 'contact:website'
        : 'website';

    _name = TextEditingController(text: _baselineTags['name'] ?? '');
    _description = TextEditingController(
      text: _baselineTags['description'] ?? '',
    );
    _housenumber = TextEditingController(
      text: _baselineTags['addr:housenumber'] ?? '',
    );
    _street = TextEditingController(text: _baselineTags['addr:street'] ?? '');
    _operator = TextEditingController(text: _baselineTags['operator'] ?? '');
    _operatorWebsite = TextEditingController(
      text: _baselineTags['operator:website'] ?? '',
    );
    _website = TextEditingController(text: _baselineTags[_websiteKey] ?? '');

    // Public bookcase.
    _bookcaseType = _baselineTags['public_bookcase:type'];
    if (_baselineTags['brand:wikidata'] == _lflWikidata ||
        _baselineTags['brand'] == _lflBrand) {
      _brand = _lflBrand;
    } else {
      _brand = _baselineTags['brand'];
    }

    // Food sharing.
    _isFridge = _baselineTags['fridge'] == 'yes';

    // Give box.
    if (_baselineTags['clothes'] == 'only') {
      _giveBoxKind = 'clothes';
    } else if (_baselineTags['shoes'] == 'only') {
      _giveBoxKind = 'shoes';
    } else if (_baselineTags['art'] == 'only') {
      _giveBoxKind = 'art';
    } else if (_baselineTags['puzzles'] == 'only') {
      _giveBoxKind = 'puzzles';
    } else if (_baselineTags['vending'] == 'pet_food') {
      _giveBoxKind = 'pet_food';
    } else {
      _giveBoxKind = 'mixed';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _housenumber.dispose();
    _street.dispose();
    _operator.dispose();
    _operatorWebsite.dispose();
    _website.dispose();
    super.dispose();
  }

  PendingEdit? _findPendingModify() {
    if (widget.isCreate) return null;
    for (final e in widget.editQueueService.pending) {
      if (e.osmId == widget.amenity!.id && e.op == PendingEditOp.modify) {
        return e;
      }
    }
    return null;
  }

  Map<String, String> _buildNewTags() {
    final tags = Map<String, String>.from(_baselineTags);

    void apply(String key, String raw) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        tags.remove(key);
      } else {
        tags[key] = trimmed;
      }
    }

    apply('name', _name.text);
    apply('description', _description.text);
    apply('addr:housenumber', _housenumber.text);
    apply('addr:street', _street.text);
    apply('operator', _operator.text);
    apply('operator:website', _operatorWebsite.text);
    apply(_websiteKey, _website.text);

    switch (widget.type) {
      case AmenityType.publicBookcase:
        if (_bookcaseType == null) {
          tags.remove('public_bookcase:type');
        } else {
          tags['public_bookcase:type'] = _bookcaseType!;
        }
        if (_brand == _lflBrand) {
          tags['brand'] = _lflBrand;
          tags['brand:wikidata'] = _lflWikidata;
        } else if (_brand == null) {
          tags.remove('brand');
          tags.remove('brand:wikidata');
        } else {
          // Custom brand preserved as-is; brand:wikidata stays untouched so
          // we don't blow away a user-curated value we don't understand.
          tags['brand'] = _brand!;
        }
      case AmenityType.foodSharing:
        if (_isFridge) {
          tags['fridge'] = 'yes';
        } else {
          tags.remove('fridge');
        }
      case AmenityType.giveBox:
        for (final k in ['clothes', 'shoes', 'art', 'puzzles']) {
          tags.remove(k);
        }
        // Only clear `vending` if it's our marker — preserve other values
        // (e.g. `vending=newspapers`) we don't manage.
        if (tags['vending'] == 'pet_food') tags.remove('vending');
        if (_giveBoxKind == 'pet_food') {
          tags['vending'] = 'pet_food';
        } else if (_giveBoxKind != 'mixed') {
          tags[_giveBoxKind] = 'only';
        }
    }

    return tags;
  }

  Future<void> _pickNewLocation() async {
    FocusScope.of(context).unfocus();
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute<LatLng>(
        builder: (_) => CreateAmenityLocationScreen(
          type: widget.type,
          settingsService: widget.settingsService,
          editQueueService: widget.editQueueService,
          initialCenter: LatLng(_currentLat, _currentLon),
          initialZoom: 17,
          initialAmenities: const [],
          title: 'Move ${_typeTitle(widget.type)}',
          actionLabel: 'Choose Location',
          previousLocation: LatLng(_currentLat, _currentLon),
          excludeAmenityId: widget.isCreate ? null : widget.amenity!.id,
          excludePendingCreateLocalId: widget.resumeFromLocalId,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _currentLat = picked.latitude;
      _currentLon = picked.longitude;
    });
    await _minimapController?.moveCamera(
      CameraUpdate.newLatLng(LatLng(_currentLat, _currentLon)),
    );
  }

  Color _typeColor() {
    switch (widget.type) {
      case AmenityType.foodSharing:
        return const Color(0xFF2E7D32);
      case AmenityType.publicBookcase:
        return const Color(0xFF1565C0);
      case AmenityType.giveBox:
        return const Color(0xFFEF6C00);
    }
  }

  Future<void> _delete() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    FocusScope.of(context).unfocus();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: const Text('Delete this point?'),
          content: const Text(
            "This queues a deletion to upload to OpenStreetMap. Only delete points that no longer exist — don't delete a point just because it's empty or temporarily unavailable.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;

    final edit = PendingEdit(
      localId: const Uuid().v4(),
      op: PendingEditOp.delete,
      osmId: widget.amenity!.id,
      baseVersion: widget.amenity!.version,
      originalLat: widget.amenity!.lat,
      originalLon: widget.amenity!.lon,
      originalTags: _originalTags,
      queuedAt: DateTime.now(),
    );

    await widget.editQueueService.enqueue(edit);
    if (!mounted) return;
    navigator.pop();
    messenger.showSnackBar(
      const SnackBar(content: Text('Queued deletion for upload.')),
    );
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    FocusScope.of(context).unfocus();
    final newTags = _buildNewTags();

    final moved = _currentLat != _baselineLat || _currentLon != _baselineLon;
    if (!widget.isCreate && !moved && _mapsEqual(newTags, _baselineTags)) {
      navigator.pop(true);
      return;
    }

    final now = DateTime.now();
    // Bump check_date unless the user opted out via the bottom checkbox. The
    // sheet's Last Updated row reads from the queued tags and reflects this
    // immediately when set.
    if (_updateCheckDate) {
      newTags['check_date'] = _isoDate(now);
    }

    final edit = widget.isCreate
        ? PendingEdit(
            // Reuse the existing localId when resuming an in-queue create so
            // enqueue's REPLACE-on-conflict overwrites that row in place.
            localId: widget.resumeFromLocalId ?? const Uuid().v4(),
            op: PendingEditOp.create,
            newLat: _currentLat,
            newLon: _currentLon,
            newTags: newTags,
            queuedAt: now,
          )
        : PendingEdit(
            localId: const Uuid().v4(),
            op: PendingEditOp.modify,
            osmId: widget.amenity!.id,
            baseVersion: widget.amenity!.version,
            originalLat: widget.amenity!.lat,
            originalLon: widget.amenity!.lon,
            originalTags: _originalTags,
            newLat: _currentLat,
            newLon: _currentLon,
            newTags: newTags,
            queuedAt: now,
          );

    await widget.editQueueService.enqueue(edit);
    if (!mounted) return;
    navigator.pop(true);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          widget.isCreate
              ? 'Queued new point for upload.'
              : 'Queued edit for upload.',
        ),
      ),
    );
  }

  static bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isCreate ? 'Create ${_typeTitle(widget.type)}' : 'Edit',
        ),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _LocationMinimap(
            lat: _currentLat,
            lon: _currentLon,
            color: _typeColor(),
            onMapCreated: (c) => _minimapController = c,
            onTap: _pickNewLocation,
          ),
          const SizedBox(height: 16),
          ..._categorySection(),
          const SizedBox(height: 24),
          const _SectionHeader('Basics'),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: _nameFieldLabel(widget.type),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Helpful description to help others find it',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionHeader('Address'),
          Row(
            children: [
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _housenumber,
                  decoration: const InputDecoration(
                    labelText: 'House #',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _street,
                  decoration: const InputDecoration(
                    labelText: 'Street',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const _SectionHeader('Contact'),
          TextField(
            controller: _operator,
            decoration: const InputDecoration(
              labelText: 'Operator',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _operatorWebsite,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Operator website',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _website,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: _websiteFieldLabel(widget.type),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Update check date to now'),
            value: _updateCheckDate,
            onChanged: (v) => setState(() => _updateCheckDate = v ?? false),
          ),
          if (!widget.isCreate) ...[
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
                onPressed: _delete,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _categorySection() {
    switch (widget.type) {
      case AmenityType.publicBookcase:
        return _publicBookcaseSection();
      case AmenityType.foodSharing:
        return _foodSharingSection();
      case AmenityType.giveBox:
        return _giveBoxSection();
    }
  }

  List<Widget> _publicBookcaseSection() => [
    const _SectionHeader('Bookcase'),
    DropdownButtonFormField<String?>(
      initialValue: _bookcaseType,
      decoration: const InputDecoration(
        labelText: 'Type',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('— Unspecified —'),
        ),
        for (final t in publicBookcaseTypes)
          DropdownMenuItem<String?>(
            value: t,
            child: Text(_snakeToTitleCase(t)),
          ),
      ],
      onChanged: (v) => setState(() => _bookcaseType = v),
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<String?>(
      initialValue: _brand,
      decoration: const InputDecoration(
        labelText: 'Brand',
        border: OutlineInputBorder(),
      ),
      items: _brandItems(),
      onChanged: (v) => setState(() => _brand = v),
    ),
  ];

  List<DropdownMenuItem<String?>> _brandItems() {
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(value: null, child: Text('— None —')),
      const DropdownMenuItem<String?>(value: _lflBrand, child: Text(_lflBrand)),
    ];
    // Preserve an unrecognized existing brand so saving doesn't silently
    // strip it.
    final currentBrand = _baselineTags['brand'];
    if (currentBrand != null && !_knownBrands.contains(currentBrand)) {
      items.add(
        DropdownMenuItem<String?>(
          value: currentBrand,
          child: Text(currentBrand),
        ),
      );
    }
    return items;
  }

  List<Widget> _foodSharingSection() => [
    const _SectionHeader('Food sharing'),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Community fridge'),
      subtitle: const Text('This is a refridgerator.'),
      value: _isFridge,
      onChanged: (v) => setState(() => _isFridge = v),
    ),
  ];

  List<Widget> _giveBoxSection() => [
    const _SectionHeader('Contents'),
    DropdownButtonFormField<String>(
      initialValue: _giveBoxKind,
      decoration: const InputDecoration(
        labelText: "What's inside?",
        border: OutlineInputBorder(),
      ),
      items: const [
        DropdownMenuItem(value: 'mixed', child: Text('Mixed / various')),
        DropdownMenuItem(value: 'clothes', child: Text('Clothes only')),
        DropdownMenuItem(value: 'shoes', child: Text('Shoes only')),
        DropdownMenuItem(value: 'art', child: Text('Art only')),
        DropdownMenuItem(value: 'puzzles', child: Text('Puzzles only')),
        DropdownMenuItem(value: 'pet_food', child: Text('Pet food only')),
      ],
      onChanged: (v) {
        if (v != null) setState(() => _giveBoxKind = v);
      },
    ),
  ];
}

class _LocationMinimap extends StatelessWidget {
  const _LocationMinimap({
    required this.lat,
    required this.lon,
    required this.color,
    required this.onMapCreated,
    required this.onTap,
  });

  final double lat;
  final double lon;
  final Color color;
  final void Function(MapLibreMapController) onMapCreated;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 160,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Stack(
            alignment: Alignment.center,
            children: [
              IgnorePointer(
                child: MapLibreMap(
                  styleString: AppConfig.mapStyleUrl,
                  initialCameraPosition: CameraPosition(
                    target: LatLng(lat, lon),
                    zoom: 17,
                  ),
                  onMapCreated: onMapCreated,
                ),
              ),
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.4),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.edit_location_alt_outlined,
                        color: Colors.white,
                        size: 16,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Move',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(label, style: theme.textTheme.titleMedium),
    );
  }
}
