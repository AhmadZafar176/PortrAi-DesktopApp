import 'package:cloud_firestore/cloud_firestore.dart';

class Preset {
  final String collectionId;
  final String presetId;
  final String title;
  final String generatedImageUrls;
  final String postProcessingUrl;
  final String createdAt;
  
  final String url;
  final String name;
  final String thumbnailPath;
  final String collection;
  
  final String prompt;
  
  final bool isNoEffects;
  
  final int lastModified;
  final bool isLocalChange;

  const Preset({
    this.collectionId = "",
    this.presetId = "",
    this.title = "",
    this.generatedImageUrls = "https:
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

  static String _parseImageUrls(dynamic value) {
    const defaultUrl = "https:
    
    assert(() {
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

  Map<String, dynamic> toJson() {
    return toMap();
  }

  factory Preset.fromJson(Map<String, dynamic> json) {
    return Preset.fromMap(json);
  }

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
