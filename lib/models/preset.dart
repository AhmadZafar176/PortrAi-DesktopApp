import 'package:cloud_firestore/cloud_firestore.dart';

class Preset {
  final String collectionId;
  final String presetId;
  final String title;
  final String generatedImageUrls; // Firebase Storage URL for thumbnail
  final String postProcessingUrl;
  final String createdAt;
  
  // Legacy fields for backward compatibility
  final String url;
  final String name;
  final String thumbnailPath;
  final String collection;
  
  // Excluded fields (not synced to Firebase)
  final String prompt; // This field is excluded from Firebase sync
  
  // Virtual field for "No Effects" preset (exactly like legacy app)
  final bool isNoEffects;
  
  // Sync metadata for conflict resolution
  final int lastModified;
  final bool isLocalChange;

  const Preset({
    this.collectionId = "",
    this.presetId = "",
    this.title = "",
    this.generatedImageUrls = "https://firebasestorage.googleapis.com/v0/b/ai-booth-edda3.firebasestorage.app/o/generations%2F1yOQlRrxwrOvv6L5urQM4pTTTFV2%2Finputs%2Fsecond%2F1760111631964_1760111619628_fk0nq2_0_WhatsApp%20Image%202025-10-10%20at%208.51.04%20PM.jpeg?alt=media&token=fd6cc553-5084-4684-9ba3-3ec036f9b384",
    this.postProcessingUrl = "",
    this.createdAt = "",
    this.url = "",
    this.name = "",
    this.thumbnailPath = "",
    this.collection = "Default",
    this.prompt = "",
    this.isNoEffects = false,
    this.lastModified = 0,
    this.isLocalChange = false,
  });

  // Factory constructor from Map (for Firebase)
  factory Preset.fromMap(Map<String, dynamic> map) {
    return Preset(
      collectionId: map['collectionId'] ?? "",
      presetId: map['presetId'] ?? "",
      title: map['title'] ?? "",
      generatedImageUrls: _parseImageUrls(map['generatedImageUrls']),
      postProcessingUrl: map['postProcessingUrl'] ?? "",
      createdAt: _parseTimestamp(map['createdAt']),
      url: map['url'] ?? "",
      name: map['name'] ?? "",
      thumbnailPath: _parseImageUrls(map['thumbnailPath']),
      collection: map['collection'] ?? "Default",
      prompt: map['prompt'] ?? "",
      isNoEffects: map['isNoEffects'] ?? false,
      lastModified: map['lastModified'] ?? DateTime.now().millisecondsSinceEpoch,
      isLocalChange: map['isLocalChange'] ?? false,
    );
  }

  // Helper method to parse Timestamp or String to String
  static String _parseTimestamp(dynamic value) {
    if (value == null) return "";
    if (value is Timestamp) {
      return value.toDate().toIso8601String();
    }
    if (value is String) {
      return value;
    }
    return value.toString();
  }

  // Helper method to parse generatedImageUrls (List or String) to String
  static String _parseImageUrls(dynamic value) {
    const defaultUrl = "https://firebasestorage.googleapis.com/v0/b/ai-booth-edda3.firebasestorage.app/o/generations%2F1yOQlRrxwrOvv6L5urQM4pTTTFV2%2Finputs%2Fsecond%2F1760111631964_1760111619628_fk0nq2_0_WhatsApp%20Image%202025-10-10%20at%208.51.04%20PM.jpeg?alt=media&token=fd6cc553-5084-4684-9ba3-3ec036f9b384";
    
    assert(() {
      // Debug-only logging
      // ignore: avoid_print
      print("🖼️ _parseImageUrls received: $value (type: ${value.runtimeType})");
      return true;
    }());
    
    if (value == null) {
      assert(() { print("   → Returning default URL (null value)"); return true; }());
      return defaultUrl;
    }
    if (value is String) {
      final result = value.isNotEmpty ? value : defaultUrl;
      assert(() { print("   → Returning: $result"); return true; }());
      return result;
    }
    if (value is List) {
      assert(() { print("   → List with ${value.length} items"); return true; }());
      // If it's a list, take the first URL
      if (value.isNotEmpty && value[0] is String) {
        final result = (value[0] as String).isNotEmpty ? value[0] as String : defaultUrl;
        assert(() { print("   → Returning first item: $result"); return true; }());
        return result;
      }
      assert(() { print("   → Returning default URL (empty or invalid list)"); return true; }());
      return defaultUrl;
    }
    assert(() { print("   → Returning default URL (unknown type)"); return true; }());
    return defaultUrl;
  }

  // Convert to Map (for Firebase)
  Map<String, dynamic> toMap() {
    return {
      'collectionId': collectionId,
      'presetId': presetId,
      'title': title,
      'generatedImageUrls': generatedImageUrls,
      'postProcessingUrl': postProcessingUrl,
      'createdAt': createdAt,
      'url': url,
      'name': name,
      'thumbnailPath': thumbnailPath,
      'collection': collection,
      'prompt': prompt,
      'isNoEffects': isNoEffects,
      'lastModified': lastModified,
      'isLocalChange': isLocalChange,
    };
  }

  // Convert to JSON (for local storage)
  Map<String, dynamic> toJson() {
    return toMap();
  }

  // Create from JSON (for local storage)
  factory Preset.fromJson(Map<String, dynamic> json) {
    return Preset.fromMap(json);
  }

  // Copy with method for updates
  Preset copyWith({
    String? collectionId,
    String? presetId,
    String? title,
    String? generatedImageUrls,
    String? postProcessingUrl,
    String? createdAt,
    String? url,
    String? name,
    String? thumbnailPath,
    String? collection,
    String? prompt,
    bool? isNoEffects,
    int? lastModified,
    bool? isLocalChange,
  }) {
    return Preset(
      collectionId: collectionId ?? this.collectionId,
      presetId: presetId ?? this.presetId,
      title: title ?? this.title,
      generatedImageUrls: generatedImageUrls ?? this.generatedImageUrls,
      postProcessingUrl: postProcessingUrl ?? this.postProcessingUrl,
      createdAt: createdAt ?? this.createdAt,
      url: url ?? this.url,
      name: name ?? this.name,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      collection: collection ?? this.collection,
      prompt: prompt ?? this.prompt,
      isNoEffects: isNoEffects ?? this.isNoEffects,
      lastModified: lastModified ?? this.lastModified,
      isLocalChange: isLocalChange ?? this.isLocalChange,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Preset &&
        other.collectionId == collectionId &&
        other.presetId == presetId &&
        other.title == title &&
        other.generatedImageUrls == generatedImageUrls &&
        other.postProcessingUrl == postProcessingUrl &&
        other.createdAt == createdAt &&
        other.url == url &&
        other.name == name &&
        other.thumbnailPath == thumbnailPath &&
        other.collection == collection &&
        other.prompt == prompt;
  }

  @override
  int get hashCode {
    return Object.hash(
      collectionId,
      presetId,
      title,
      generatedImageUrls,
      postProcessingUrl,
      createdAt,
      url,
      name,
      thumbnailPath,
      collection,
      prompt,
    );
  }

  @override
  String toString() {
    return 'Preset(collectionId: $collectionId, presetId: $presetId, title: $title, generatedImageUrls: $generatedImageUrls, postProcessingUrl: $postProcessingUrl, createdAt: $createdAt, url: $url, name: $name, thumbnailPath: $thumbnailPath, collection: $collection, prompt: $prompt)';
  }
}
