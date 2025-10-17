import 'package:cloud_firestore/cloud_firestore.dart';
import 'preset.dart';

class Collection {
  final String id;
  final String name;
  final String description;
  final String thumbnailPath; // Collection thumbnail
  final List<Preset> presets;

  const Collection({
    required this.id,
    required this.name,
    this.description = "",
    this.thumbnailPath = "",
    this.presets = const [],
  });

  // Factory constructor from Map (for Firebase)
  factory Collection.fromMap(Map<String, dynamic> map) {
    return Collection(
      id: map['id'] ?? "",
      name: map['name'] ?? "",
      description: map['description'] ?? "",
      thumbnailPath: map['thumbnailPath'] ?? "",
      presets: (map['presets'] as List<dynamic>?)
          ?.map((preset) => Preset.fromMap(preset as Map<String, dynamic>))
          .toList() ?? [],
    );
  }

  // Convert to Map (for Firebase)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'thumbnailPath': thumbnailPath,
      'presets': presets.map((preset) => preset.toMap()).toList(),
    };
  }

  // Convert to JSON (for local storage)
  Map<String, dynamic> toJson() {
    return toMap();
  }

  // Create from JSON (for local storage)
  factory Collection.fromJson(Map<String, dynamic> json) {
    return Collection.fromMap(json);
  }

  // Copy with method for updates
  Collection copyWith({
    String? id,
    String? name,
    String? description,
    String? thumbnailPath,
    List<Preset>? presets,
  }) {
    return Collection(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      presets: presets ?? this.presets,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Collection &&
        other.id == id &&
        other.name == name &&
        other.description == description &&
        other.thumbnailPath == thumbnailPath &&
        other.presets == presets;
  }

  @override
  int get hashCode {
    return Object.hash(id, name, description, thumbnailPath, presets);
  }

  @override
  String toString() {
    return 'Collection(id: $id, name: $name, description: $description, thumbnailPath: $thumbnailPath, presets: $presets)';
  }
}
