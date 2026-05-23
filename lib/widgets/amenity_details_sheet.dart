import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../models/amenity.dart';
import '../models/pending_edit.dart';
import '../screens/edit_amenity_screen.dart';
import '../services/edit_queue_service.dart';
import '../services/osm_auth_service.dart';
import '../services/settings_service.dart';

// A node is "stale" if the most recent date we have for it is older than
// this. Drives the Verify button on the Last Updated row.
const _stalenessThreshold = Duration(days: 7);

// Verify is only offered when the user is at most this many meters from the
// POI — the whole point is that they're physically at the spot and can
// confirm it's still there.
const _verifyRangeMeters = 150.0;

String _snakeToTitleCase(String value) => value
    .split('_')
    .where((w) => w.isNotEmpty)
    .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

const _monthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _isoDate(DateTime dt) =>
    '${dt.year.toString().padLeft(4, '0')}-'
    '${dt.month.toString().padLeft(2, '0')}-'
    '${dt.day.toString().padLeft(2, '0')}';

String? _formatDateAsCheckDate(DateTime? dt) {
  if (dt == null) return null;
  return _formatCheckDate(_isoDate(dt));
}

/// Accepts `YYYY`, `YYYY-MM`, or `YYYY-MM-DD` and formats as
/// "2026", "January 2026", or "January 30, 2026". Returns null if the input
/// doesn't match one of those shapes (so the row is just omitted).
String? _formatCheckDate(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$').firstMatch(raw);
  if (match == null) return null;
  final year = match.group(1)!;
  final monthStr = match.group(2);
  final dayStr = match.group(3);
  if (monthStr == null) return year;
  final monthIdx = int.parse(monthStr);
  if (monthIdx < 1 || monthIdx > 12) return null;
  final monthName = _monthNames[monthIdx - 1];
  if (dayStr == null) return '$monthName $year';
  final day = int.parse(dayStr);
  if (day < 1 || day > 31) return null;
  return '$monthName $day, $year';
}

/// Parse a `YYYY`/`YYYY-MM`/`YYYY-MM-DD` string into a DateTime at the start
/// of that period. Used for staleness comparisons — start-of-period means
/// coarse dates look as old as they could be, which favors prompting a
/// re-check.
DateTime? _parseCheckDateAsDateTime(String? raw) {
  if (raw == null) return null;
  final match = RegExp(r'^(\d{4})(?:-(\d{2})(?:-(\d{2}))?)?$').firstMatch(raw);
  if (match == null) return null;
  final y = int.parse(match.group(1)!);
  final m = int.tryParse(match.group(2) ?? '') ?? 1;
  final d = int.tryParse(match.group(3) ?? '') ?? 1;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  return DateTime(y, m, d);
}

DateTime? _lastUpdatedDate(Amenity amenity) {
  return _parseCheckDateAsDateTime(amenity.tags['check_date']) ??
      amenity.lastEditedAt?.toLocal();
}

bool _isStale(Amenity amenity) {
  final d = _lastUpdatedDate(amenity);
  if (d == null) return false;
  return DateTime.now().difference(d) > _stalenessThreshold;
}

class AmenityDetailsSheet extends StatelessWidget {
  const AmenityDetailsSheet({
    super.key,
    required this.amenity,
    required this.authService,
    required this.editQueueService,
    required this.settingsService,
    this.userPosition,
    this.pendingCreateLocalId,
  });

  final Amenity amenity;
  final OsmAuthService authService;
  final EditQueueService editQueueService;
  final SettingsService settingsService;

  /// Latest known user position — sourced from HomeScreen, which fetches it
  /// whenever the locate-me FAB runs. Null when MapLibre isn't showing the
  /// user's location, in which case Verify stays hidden.
  final Position? userPosition;

  /// When [amenity] is a synthetic POI built from a queued `create`, this is
  /// the corresponding PendingEdit.localId — used to find the queue entry
  /// since synthetic amenities have no OSM id to match on.
  final String? pendingCreateLocalId;

  void _onEdit(BuildContext context, {PendingEdit? pendingEdit}) {
    // Push without popping the sheet — when the edit screen pops, the user
    // returns to this same sheet, which rebuilds via ListenableBuilder and
    // reflects the new queued edit.
    final isPendingCreate =
        pendingEdit != null && pendingEdit.op == PendingEditOp.create;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => isPendingCreate
            ? EditAmenityScreen.create(
                initialType: amenity.type,
                initialLat: amenity.lat,
                initialLon: amenity.lon,
                editQueueService: editQueueService,
                settingsService: settingsService,
                resumeFromLocalId: pendingEdit.localId,
                initialTags: pendingEdit.newTags,
              )
            : EditAmenityScreen.modify(
                amenity: amenity,
                editQueueService: editQueueService,
                settingsService: settingsService,
              ),
      ),
    );
  }

  Future<void> _onVerify(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final now = DateTime.now();
    final newTags = Map<String, String>.from(amenity.tags);
    newTags['check_date'] = _isoDate(now);
    final edit = PendingEdit(
      localId: const Uuid().v4(),
      op: PendingEditOp.modify,
      osmId: amenity.id,
      baseVersion: amenity.version,
      originalLat: amenity.lat,
      originalLon: amenity.lon,
      originalTags: Map<String, String>.from(amenity.tags),
      newLat: amenity.lat,
      newLon: amenity.lon,
      newTags: newTags,
      queuedAt: now,
    );
    await editQueueService.enqueue(edit);
    messenger.showSnackBar(
      const SnackBar(content: Text('Queued check-in for upload.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signedIn = authService.currentUser != null;
    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      minChildSize: 0.25,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListenableBuilder(
                listenable: editQueueService,
                builder: (context, _) {
                  PendingEdit? pendingEdit;
                  final localIdHint = pendingCreateLocalId;
                  for (final e in editQueueService.pending) {
                    if (localIdHint != null) {
                      if (e.localId == localIdHint) {
                        pendingEdit = e;
                        break;
                      }
                    } else if (e.osmId == amenity.id) {
                      pendingEdit = e;
                      break;
                    }
                  }
                  // Display state reflects whatever is queued so the user
                  // sees their edits without waiting for upload. For
                  // delete, newTags/newLat/newLon are null and the
                  // fallbacks preserve the original snapshot.
                  final effective = pendingEdit != null
                      ? Amenity(
                          id: amenity.id,
                          type: amenity.type,
                          lat: pendingEdit.newLat ?? amenity.lat,
                          lon: pendingEdit.newLon ?? amenity.lon,
                          tags: pendingEdit.newTags ?? amenity.tags,
                          version: amenity.version,
                          lastEditedAt: amenity.lastEditedAt,
                        )
                      : amenity;
                  final pos = userPosition;
                  final withinRange =
                      pos != null &&
                      Geolocator.distanceBetween(
                            pos.latitude,
                            pos.longitude,
                            amenity.lat,
                            amenity.lon,
                          ) <=
                          _verifyRangeMeters;
                  final showVerify =
                      signedIn &&
                      _isStale(effective) &&
                      pendingEdit == null &&
                      withinRange;
                  return ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    children: [
                      _Header(amenity: effective),
                      if (pendingEdit != null) ...[
                        const SizedBox(height: 16),
                        _PendingEditBanner(edit: pendingEdit),
                      ],
                      const SizedBox(height: 16),
                      _MetadataSection(amenity: effective),
                      if (signedIn) ...[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () =>
                                  _onEdit(context, pendingEdit: pendingEdit),
                              icon: const Icon(Icons.edit, size: 18),
                              label: const Text('Edit'),
                            ),
                            if (showVerify)
                              FilledButton.tonalIcon(
                                onPressed: () => _onVerify(context),
                                icon: const Icon(Icons.check, size: 18),
                                label: const Text('Verify'),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),
                      _AdvancedSection(amenity: effective),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.amenity});

  final Amenity amenity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _typeColor(amenity.type);
    final name = amenity.tags['name'];
    final title = name ?? amenity.typeLabel;
    final subtitle =
        (name == null || name.toLowerCase() == amenity.typeLabel.toLowerCase())
        ? null
        : amenity.typeLabel;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 14,
          height: 14,
          margin: const EdgeInsets.only(top: 6),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static Color _typeColor(AmenityType type) {
    switch (type) {
      case AmenityType.foodSharing:
        return const Color(0xFF2E7D32);
      case AmenityType.publicBookcase:
        return const Color(0xFF1565C0);
      case AmenityType.giveBox:
        return const Color(0xFFEF6C00);
    }
  }
}

class _MetadataSection extends StatelessWidget {
  const _MetadataSection({required this.amenity});

  final Amenity amenity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tags = amenity.tags;
    final rows = <Widget>[];

    final description = tags['description'];
    if (description != null) {
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SelectableText(description, style: theme.textTheme.bodyMedium),
        ),
      );
    }

    void addRow(IconData icon, String label, String? value, {String? url}) {
      if (value == null) return;
      rows.add(_IconRow(icon: icon, label: label, value: value, url: url));
    }

    final house = tags['addr:housenumber'];
    final street = tags['addr:street'];
    if (house != null && street != null) {
      addRow(Icons.location_on_outlined, 'Address', '$house $street');
    }
    if (amenity.type == AmenityType.publicBookcase) {
      final bookcaseType = tags['public_bookcase:type'];
      if (bookcaseType != null && publicBookcaseTypes.contains(bookcaseType)) {
        addRow(
          Icons.category_outlined,
          'Type',
          _snakeToTitleCase(bookcaseType),
        );
      }
    }
    addRow(
      Icons.business_outlined,
      'Operator',
      tags['operator'],
      url: tags['operator:website'],
    );
    addRow(Icons.schedule_outlined, 'Hours', tags['opening_hours']);
    final website = tags['website'] ?? tags['contact:website'];
    addRow(Icons.link, 'Website', website, url: website);
    addRow(
      Icons.phone_outlined,
      'Phone',
      tags['phone'] ?? tags['contact:phone'],
    );
    final lastUpdated =
        _formatCheckDate(tags['check_date']) ??
        _formatDateAsCheckDate(amenity.lastEditedAt?.toLocal());
    addRow(Icons.update, 'Last Updated', lastUpdated);

    if (rows.isEmpty) {
      return Text(
        'No additional details.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}

class _PendingEditBanner extends StatefulWidget {
  const _PendingEditBanner({required this.edit});

  final PendingEdit edit;

  @override
  State<_PendingEditBanner> createState() => _PendingEditBannerState();
}

class _PendingEditBannerState extends State<_PendingEditBanner> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onContainer = theme.colorScheme.onPrimaryContainer;
    return Material(
      color: theme.colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _expanded = !_expanded),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.topCenter,
          curve: Curves.easeInOut,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.cloud_upload_outlined,
                      size: 18,
                      color: onContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Pending — not yet uploaded',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: onContainer,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: onContainer,
                    ),
                  ],
                ),
                if (_expanded) ...[
                  const SizedBox(height: 8),
                  for (final line in _lines())
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        line,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onContainer,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<String> _lines() {
    final edit = widget.edit;
    switch (edit.op) {
      case PendingEditOp.delete:
        return const ['This node will be deleted.'];
      case PendingEditOp.create:
        return const ['This is a new node.'];
      case PendingEditOp.modify:
        final lines = <String>[];
        if (edit.originalLat != edit.newLat ||
            edit.originalLon != edit.newLon) {
          lines.add('Location: moved');
        }
        final orig = edit.originalTags ?? const <String, String>{};
        final updated = edit.newTags ?? const <String, String>{};
        final keys = (<String>{...orig.keys, ...updated.keys}).toList()..sort();
        for (final k in keys) {
          final o = orig[k];
          final n = updated[k];
          if (o == n) continue;
          if (o == null) {
            lines.add('$k: $n');
          } else if (n == null) {
            lines.add('$k: removed');
          } else {
            lines.add('$k: $o → $n');
          }
        }
        if (lines.isEmpty) lines.add('No changes detected.');
        return lines;
    }
  }
}

class _IconRow extends StatelessWidget {
  const _IconRow({
    required this.icon,
    required this.label,
    required this.value,
    this.url,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? url;

  Future<void> _openUrl() async {
    final uri = Uri.tryParse(url!);
    if (uri == null) return;
    await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasUrl = url != null;
    final Widget valueWidget = hasUrl
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.open_in_new,
                size: 14,
                color: theme.colorScheme.primary,
              ),
            ],
          )
        : SelectableText(value, style: theme.textTheme.bodyMedium);

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                valueWidget,
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!hasUrl) return content;
    return InkWell(
      onTap: _openUrl,
      borderRadius: BorderRadius.circular(8),
      child: content,
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({required this.amenity});

  final Amenity amenity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      // Hide the default ExpansionTile borders.
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        title: Text('Advanced', style: theme.textTheme.titleSmall),
        children: [
          _RawDetailRow(
            label: 'Coordinates',
            value:
                '${amenity.lat.toStringAsFixed(5)}, ${amenity.lon.toStringAsFixed(5)}',
          ),
          // id == 0 is the sentinel HomeScreen uses for synthetic POIs built
          // from a queued create — there's no OSM node yet to reference.
          if (amenity.id != 0)
            _RawDetailRow(label: 'OSM node', value: '#${amenity.id}'),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Tags', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: 4),
          for (final entry in amenity.tags.entries)
            _RawDetailRow(label: entry.key, value: entry.value),
        ],
      ),
    );
  }
}

class _RawDetailRow extends StatelessWidget {
  const _RawDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
