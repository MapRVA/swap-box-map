class OsmUser {
  const OsmUser({required this.id, required this.displayName, this.imageUrl});

  final int id;
  final String displayName;
  final String? imageUrl;

  factory OsmUser.fromJson(Map<String, dynamic> json) {
    final img = json['img'];
    return OsmUser(
      id: json['id'] as int,
      displayName: json['display_name'] as String,
      imageUrl: img is Map<String, dynamic> ? img['href'] as String? : null,
    );
  }
}
