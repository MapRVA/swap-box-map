/// `public_bookcase:type` values we recognize. Used both to filter junk tag
/// values when displaying, and to populate the bookcase-type dropdown on the
/// edit screen.
const publicBookcaseTypes = <String>{
  'wooden_cabinet',
  'phone_box',
  'reading_box',
  'shelf',
  'glass_cabinet',
  'metal_cabinet',
  'shelter',
  'fridge',
  'sculpture',
  'building',
  'movable_cabinet',
  'wooden_box',
  'cabinet',
  'wall_cabinet',
  'barrel',
  'refrigerator',
};

enum AmenityType {
  foodSharing('food_sharing'),
  publicBookcase('public_bookcase'),
  giveBox('give_box');

  const AmenityType(this.osmValue);

  final String osmValue;

  static AmenityType? fromOsmValue(String? value) {
    for (final t in AmenityType.values) {
      if (t.osmValue == value) return t;
    }
    return null;
  }
}

class Amenity {
  const Amenity({
    required this.id,
    required this.type,
    required this.lat,
    required this.lon,
    required this.tags,
    this.version,
    this.lastEditedAt,
  });

  final int id;
  final AmenityType type;
  final double lat;
  final double lon;
  final Map<String, String> tags;

  /// OSM version of the node, used as the base version when queuing
  /// modify/delete edits so the API can detect concurrent changes. Null if
  /// the Overpass response didn't include metadata.
  final int? version;

  /// Last edit timestamp reported by OSM (`out meta;` in Overpass). Null if
  /// the response didn't include metadata.
  final DateTime? lastEditedAt;

  String get typeLabel {
    switch (type) {
      case AmenityType.foodSharing:
        if (tags['fridge'] == 'yes') return 'Community Fridge';
        return 'Food Sharing';
      case AmenityType.publicBookcase:
        if (tags['brand'] == 'Little Free Library' ||
            tags['brand:wikidata'] == 'Q6650101') {
          return 'Little Free Library';
        }
        return 'Public Bookcase';
      case AmenityType.giveBox:
        if (tags['clothes'] == 'only') return 'Clothing Exchange Box';
        if (tags['shoes'] == 'only') return 'Shoe Exchange Box';
        if (tags['art'] == 'only') return 'Art Exchange Box';
        if (tags['puzzles'] == 'only') return 'Puzzle Exchange Box';
        if (tags['vending'] == 'pet_food') return 'Pet Food Sharing';
        return 'Give Box';
    }
  }

  static Amenity? fromOverpassNode(Map<String, dynamic> node) {
    final rawTags = node['tags'];
    if (rawTags is! Map) return null;
    final tags = rawTags.map((k, v) => MapEntry(k.toString(), v.toString()));
    var type = AmenityType.fromOsmValue(tags['amenity']);
    if (type == null) return null;
    // Some nodes are categorized as `amenity=food_sharing` upstream but
    // belong in the give-box bucket for our filtering/display purposes.
    // `vending=pet_food` is one such case (pet food sharing boxes).
    if (type == AmenityType.foodSharing && tags['vending'] == 'pet_food') {
      type = AmenityType.giveBox;
    }
    final timestamp = node['timestamp'];
    final version = node['version'];
    return Amenity(
      id: node['id'] as int,
      type: type,
      lat: (node['lat'] as num).toDouble(),
      lon: (node['lon'] as num).toDouble(),
      tags: tags,
      version: version is int ? version : null,
      lastEditedAt: timestamp is String ? DateTime.tryParse(timestamp) : null,
    );
  }
}
