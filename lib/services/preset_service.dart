import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/preset.dart';
import '../models/collection.dart';
import 'auth_service.dart';
import 'log_service.dart';

class PresetService {
  static final PresetService _instance = PresetService._internal();
  factory PresetService() => _instance;
  PresetService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final AuthService _authService = AuthService();

  // Local cache for offline-first approach
  List<Preset> _localPresets = [];
  List<Collection> _localCollections = [];
  List<Preset> _localPostDeliveryPresets = [];
  List<Collection> _localPostDeliveryCollections = [];

  // Map real Firestore collection name -> collectionId for correct writes
  final Map<String, String> _collectionNameToId = {};

  // Sync state tracking
  bool _presetsLoadedFromFirebase = false;
  bool _collectionsLoadedFromFirebase = false;
  bool _postDeliveryPresetsLoadedFromFirebase = false;
  bool _postDeliveryCollectionsLoadedFromFirebase = false;
  DateTime? _lastFirebaseSync;
  static const Duration _firebaseSyncInterval = Duration(minutes: 5);
  bool _initialSyncCompleted = false;
  bool _isInitialListenerFire = true; // Track if this is the first listener fire

  // Debounced save timers - exactly like legacy app
  final Map<String, Timer> _debounceTimers = {};

  // Real-time Firebase listeners
  StreamSubscription<QuerySnapshot>? _collectionsListener;
  StreamSubscription<QuerySnapshot>? _presetsListener;
  bool _isListening = false;
  
  // Sync state management
  final Set<String> _editingPresets = <String>{}; // Track presets being edited
  final Map<String, int> _retryCounts = <String, int>{}; // Track retry attempts
  static const int _maxRetries = 3;

  // Callback for notifying AppState of changes
  VoidCallback? _onDataChanged;

  // Current data source
  String _dataSource = 'live';

  // Getters
  List<Preset> get localPresets => _localPresets;
  List<Collection> get localCollections => _localCollections;
  List<Preset> get localPostDeliveryPresets => _localPostDeliveryPresets;
  List<Collection> get localPostDeliveryCollections => _localPostDeliveryCollections;

  // Initialize service
  Future<void> initialize() async {
    // ignore: avoid_print
    print('PresetService:initialize');
    await _loadFromLocalCache();
    await _loadUserDataFromFirebase();
    await _startRealtimeListeners();
  }

  // Load data from Firebase with smart sync strategy - exactly like legacy app
  Future<void> _loadUserDataFromFirebase() async {
    final user = _authService.currentUser;
    if (user == null) return;

    final currentTime = DateTime.now();
    
    // Always load from local cache first for instant UI response - exactly like legacy
    await _loadFromLocalCache();
    print("📁 Loaded data from local cache");

    // Only sync with Firebase if:
    // 1. Initial sync not completed yet, OR
    // 2. More than 5 minutes since last sync
    final needsSync = !_initialSyncCompleted || 
                     _lastFirebaseSync == null ||
                     currentTime.difference(_lastFirebaseSync!) > _firebaseSyncInterval;

    if (needsSync) {
      print("🔄 Performing Firebase sync...");
      await _performFirebaseSync();
      _initialSyncCompleted = true;
      _lastFirebaseSync = currentTime;
      await LogService.log('PresetService: Firebase sync complete');
    } else {
      print("🚀 Using cached data, Firebase sync not needed");
    }
  }

  // Perform Firebase sync operations - exactly like legacy app
  Future<void> _performFirebaseSync() async {
    try {
      // Store current local data before sync
      final currentLocalPresets = List<Preset>.from(_localPresets);
      final currentLocalCollections = List<Collection>.from(_localCollections);
      
      // Fetch fresh data from Firebase
      await _fetchUserPresets();
      await _fetchUserCollections();
      
      // Merge Firebase data with local changes - exactly like legacy app
      _mergeLocalChangesWithFirebaseData(currentLocalPresets, currentLocalCollections);
      
      await _saveLocalCache();
      print("✅ Firebase sync completed successfully");
    } catch (e) {
      print("❌ Firebase sync failed: $e, using local cache");
      // Keep using local cache if Firebase sync fails
    }
  }

  // Fetch user presets from Firebase - exactly like legacy app
  Future<void> _fetchUserPresets() async {
    final user = _authService.currentUser;
    if (user == null) return;

    try {
      _localPresets.clear();
      _localPostDeliveryPresets.clear();

      // Fetch all presets from collections path and categorize by presetType
      await _fetchAllPresetsFromCollections(user.uid);

      _presetsLoadedFromFirebase = true;
      print("✅ Loaded ${_localPresets.length} live presets and ${_localPostDeliveryPresets.length} post-delivery presets");
    } catch (e) {
      print("❌ Error fetching presets: $e");
    }
  }

  // Fetch all presets from collections and categorize by presetType
  Future<void> _fetchAllPresetsFromCollections(String userId) async {
    try {
      final userDoc = _firestore.collection('users').doc(userId);
      final collectionsSnapshot = await userDoc.collection('collections').get();

      for (final collectionDoc in collectionsSnapshot.docs) {
        final collectionData = collectionDoc.data();
        final collectionName = collectionData['name'] ?? 'Default';
        final collectionId = collectionDoc.id;
        
        print("🔍 Fetching presets from collection: $collectionName");
        
        // Get presets from this collection
        final presetsSnapshot = await collectionDoc.reference.collection('presets').get();
        
        for (final presetDoc in presetsSnapshot.docs) {
          final presetData = presetDoc.data();

          // Create Preset object; always use document path ID as presetId
          final preset = Preset.fromMap({
            'collectionId': presetData['collectionId'] ?? collectionId,
            'presetId': presetDoc.id,
            'title': presetData['title'] ?? '',
            'generatedImageUrls': presetData['generatedImageUrls'],
            'postProcessingUrl': presetData['postProcessingUrl'] ?? '',
            'createdAt': presetData['createdAt'] ?? '',
            'name': presetData['title'] ?? '',
            'url': presetData['postProcessingUrl'] ?? '',
            'thumbnailPath': presetData['generatedImageUrls'],
            'collection': collectionName,
            'prompt': presetData['prompt'] ?? '',
          });

          // Categorize by presetType field
          final presetType = presetData['presetType'] ?? 'nano-banana'; // Default to nano-banana
          print("📄 Preset '${preset.title}' has presetType: $presetType");
          print("   generatedImageUrls: ${preset.generatedImageUrls}");
          
          if (presetType == 'post-delivery') {
            _localPostDeliveryPresets.add(preset);
            print("✅ Added to POST-DELIVERY presets");
          } else {
            _localPresets.add(preset);
            print("✅ Added to LIVE presets");
          }
        }
      }
      
      print("✅ Fetched ${_localPresets.length} LIVE presets and ${_localPostDeliveryPresets.length} POST-DELIVERY presets from collections");
    } catch (e) {
      print("❌ Error fetching presets from collections: $e");
    }
  }

  // Fetch user collections from Firebase - exactly like legacy app
  Future<void> _fetchUserCollections() async {
    final user = _authService.currentUser;
    if (user == null) return;

    try {
      _localCollections.clear();
      _localPostDeliveryCollections.clear();

      // Fetch all collections from collections path
      await _fetchAllCollections(user.uid);
      
      // Create separate collections for Live and Post-Delivery based on presetType
      await _categorizeCollectionsByPresetType();

      _collectionsLoadedFromFirebase = true;
      print("✅ Loaded ${_localCollections.length} live collections and ${_localPostDeliveryCollections.length} post-delivery collections");
    } catch (e) {
      print("❌ Error fetching collections: $e");
    }
  }

  // Fetch all collections from collections path
  Future<void> _fetchAllCollections(String userId) async {
    try {
      final userDoc = _firestore.collection('users').doc(userId);
      final collectionsSnapshot = await userDoc.collection('collections').get();

      for (final doc in collectionsSnapshot.docs) {
        final data = doc.data();
        final collection = Collection(
          id: doc.id,
          name: data['name'] ?? 'Default',
          description: data['description'] ?? '',
        );

        // Add to both lists initially - will be categorized later
        _localCollections.add(collection);
        _localPostDeliveryCollections.add(collection);
      }
      
      print("✅ Fetched ${_localCollections.length} collections from Firebase");
    } catch (e) {
      print("❌ Error fetching collections: $e");
    }
  }

  // Categorize collections based on their presets' presetType
  Future<void> _categorizeCollectionsByPresetType() async {
    try {
      // Clear both lists
      _localCollections.clear();
      _localPostDeliveryCollections.clear();
      
      // Get unique collection names from LIVE presets only
      final Set<String> liveCollectionNames = {};
      for (final preset in _localPresets) {
        if (preset.collection.isNotEmpty) {
          liveCollectionNames.add(preset.collection);
        }
      }

      // Get unique collection names from POST-DELIVERY presets only
      final Set<String> postDeliveryCollectionNames = {};
      for (final preset in _localPostDeliveryPresets) {
        if (preset.collection.isNotEmpty) {
          postDeliveryCollectionNames.add(preset.collection);
        }
      }

      // Create live collections (only if they have live presets)
      for (final collectionName in liveCollectionNames) {
        final liveCollection = Collection(
          id: 'live-$collectionName',
          name: collectionName,
          description: 'Live collection for $collectionName',
        );
        _localCollections.add(liveCollection);
      }

      // Create post-delivery collections (only if they have post-delivery presets)
      for (final collectionName in postDeliveryCollectionNames) {
        final postDeliveryCollection = Collection(
          id: 'post-delivery-$collectionName',
          name: collectionName,
          description: 'Post-Delivery collection for $collectionName',
        );
        _localPostDeliveryCollections.add(postDeliveryCollection);
      }
      
      // categorized collections
    } catch (e) {
      print("❌ Error categorizing collections: $e");
    }
  }

  // Create collection in Firebase - exactly like legacy app
  Future<void> createCollectionInFirebase(String collectionName, String collectionId) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    try {
      // Prepare collection data with exact name user entered - exactly like legacy
      final collectionData = {
        'name': collectionName,  // Exact name as user entered
        'description': '$collectionName collection',
        'createdAt': DateTime.now().millisecondsSinceEpoch.toString(),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };

      // Create collection document in Firebase - exact path from legacy app
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .doc(collectionId)
          .set(collectionData);

      print("✅ Created collection '$collectionName' with ID '$collectionId' in Firebase");
    } catch (e) {
      print("❌ Error creating collection in Firebase: $e");
      rethrow;
    }
  }

  // addPreset removed (creation not used)

  // Helper method to find preset index in either list
  int _findPresetIndex(String presetId) {
    // Check live presets first
    for (int i = 0; i < _localPresets.length; i++) {
      if (_localPresets[i].presetId == presetId) {
        return i;
      }
    }
    // Check post-delivery presets
    for (int i = 0; i < _localPostDeliveryPresets.length; i++) {
      if (_localPostDeliveryPresets[i].presetId == presetId) {
        return i + _localPresets.length; // Offset by live presets length
      }
    }
    return -1; // Not found
  }

  // Helper method to get preset from either list
  Preset? _getPresetById(String presetId) {
    // Check live presets first
    for (final preset in _localPresets) {
      if (preset.presetId == presetId) {
        return preset;
      }
    }
    // Check post-delivery presets
    for (final preset in _localPostDeliveryPresets) {
      if (preset.presetId == presetId) {
        return preset;
      }
    }
    return null; // Not found
  }

  // Update a preset by index (from filtered list)
  Future<void> updatePreset(int index, Preset updatedPreset) async {
    // Get the current preset at this index from the filtered list
    final currentPreset = getPresetByIndex(index, _dataSource);
    if (currentPreset == null) return;
    
    final presetId = currentPreset.presetId;
    if (presetId.isEmpty) return;
    
    // Check if it's in live presets
    for (int i = 0; i < _localPresets.length; i++) {
      if (_localPresets[i].presetId == presetId) {
        _localPresets[i] = updatedPreset;
        await _saveLocalCache();
        break;
      }
    }
    
    // Check if it's in post-delivery presets
    for (int i = 0; i < _localPostDeliveryPresets.length; i++) {
      if (_localPostDeliveryPresets[i].presetId == presetId) {
        _localPostDeliveryPresets[i] = updatedPreset;
        await _saveLocalCache();
        break;
      }
    }

    // Try to sync to Firebase (handle collection move atomically)
    try {
      final collectionChanged =
          (currentPreset.collectionId != updatedPreset.collectionId) ||
          (currentPreset.collection != updatedPreset.collection);

      if (collectionChanged) {
        await movePresetBetweenCollections(
          originalPreset: currentPreset,
          updatedPreset: updatedPreset,
        );
        print("✅ Preset '${updatedPreset.title}' moved from '${currentPreset.collection}' to '${updatedPreset.collection}'");
      } else {
        await _updatePresetInFirebase(updatedPreset);
        print("✅ Preset '${updatedPreset.title}' updated and synced to Firebase");
      }
    } catch (e) {
      print("⚠️ Preset '${updatedPreset.title}' updated locally, Firebase sync failed: $e");
    }
  }

  // Delete a preset by index (from filtered list)
  Future<void> deletePreset(int index) async {
    // Get the current preset at this index from the filtered list
    final presetToDelete = getPresetByIndex(index, _dataSource);
    if (presetToDelete == null) return;
    
    final presetId = presetToDelete.presetId;
    if (presetId.isEmpty) return;
    
    // Remove from live presets
    _localPresets.removeWhere((preset) => preset.presetId == presetId);
    
    // Remove from post-delivery presets
    _localPostDeliveryPresets.removeWhere((preset) => preset.presetId == presetId);
    
    await _saveLocalCache();

    // Try to sync to Firebase
    // Firebase deletion removed (editing/deletion disabled)
  }

  // Add preset to Firebase - exactly like legacy app
  Future<void> _addPresetToFirebase(Preset preset) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    // Get collection name, default to 'Default' if not specified - exactly like legacy
    final collectionName = preset.collection.isNotEmpty ? preset.collection : 'Default';
    
    // Resolve collectionId: prefer existing ID by name; else use preset's ID; else generate
    String collectionId = preset.collectionId;
    final desiredCollectionName = preset.collection.isNotEmpty ? preset.collection : 'Default';
    if (_collectionNameToId.containsKey(desiredCollectionName)) {
      collectionId = _collectionNameToId[desiredCollectionName]!;
    }
    if (collectionId.isEmpty) {
      collectionId = _generateCollectionId();
      // Create the collection if it's new so the path exists
      await createCollectionInFirebase(desiredCollectionName, collectionId);
      _collectionNameToId[desiredCollectionName] = collectionId;
    }
    
    // Determine presetType based on data source ('live' -> 'nano-banana', 'post' -> 'post-delivery')
    final presetType = _dataSource == 'live' ? 'nano-banana' : 'post-delivery';
    
    // Prepare preset data with presetType field
    final presetData = {
      'presetId': preset.presetId,
      'title': preset.title.isNotEmpty ? preset.title : preset.name,
      'generatedImageUrls': preset.generatedImageUrls,
      'postProcessingUrl': preset.postProcessingUrl,
      'createdAt': preset.createdAt.isNotEmpty ? preset.createdAt : DateTime.now().millisecondsSinceEpoch.toString(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'presetType': presetType, // Add presetType field
      'collectionId': collectionId,
      'collection': collectionName,
    };

    // All presets are saved to the same path: users/{userId}/collections/{collectionId}/presets/{presetId}
    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('collections')
        .doc(collectionId)
        .collection('presets')
        .doc(preset.presetId)
        .set(presetData);
        
    print("✅ Preset '${preset.title.isNotEmpty ? preset.title : preset.name}' (type: $presetType) saved to Firebase collections/$collectionId/presets/${preset.presetId}");
  }

  // Update preset in Firebase - exactly like legacy app
  Future<void> _updatePresetInFirebase(Preset preset) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    // Get collection name, default to 'Default' if not specified - exactly like legacy
    final collectionName = preset.collection.isNotEmpty ? preset.collection : 'Default';
    
    // Resolve collectionId as in add
    String collectionId = preset.collectionId;
    final desiredCollectionName = preset.collection.isNotEmpty ? preset.collection : 'Default';
    if (_collectionNameToId.containsKey(desiredCollectionName)) {
      collectionId = _collectionNameToId[desiredCollectionName]!;
    }
    if (collectionId.isEmpty) {
      collectionId = _generateCollectionId();
      await createCollectionInFirebase(desiredCollectionName, collectionId);
      _collectionNameToId[desiredCollectionName] = collectionId;
    }
    
    // Determine presetType based on data source ('live' -> 'nano-banana', 'post' -> 'post-delivery')
    final presetType = _dataSource == 'live' ? 'nano-banana' : 'post-delivery';
    
    // Prepare preset data with presetType field
    final presetData = {
      'collectionId': collectionId,  // Inherited from collection
      'presetId': preset.presetId,
      'title': preset.title.isNotEmpty ? preset.title : preset.name,
      'generatedImageUrls': preset.generatedImageUrls,
      'postProcessingUrl': preset.postProcessingUrl,
      'createdAt': preset.createdAt.isNotEmpty ? preset.createdAt : DateTime.now().millisecondsSinceEpoch.toString(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'presetType': presetType, // Add presetType field
      'collection': collectionName,
    };

    // Update in Firebase using Firestore SDK - exact path from legacy app
    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('collections')
        .doc(collectionId)
        .collection('presets')
        .doc(preset.presetId)
        .update(presetData);
  }

  /// Atomically move a preset from its old collection to a new collection in Firebase
  Future<void> movePresetBetweenCollections({
    required Preset originalPreset,
    required Preset updatedPreset,
  }) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    // Resolve IDs
    String oldCollectionId = originalPreset.collectionId;
    if (oldCollectionId.isEmpty) {
      // Try resolve from name map if available
      final oldName = originalPreset.collection.isNotEmpty ? originalPreset.collection : 'Default';
      if (_collectionNameToId.containsKey(oldName)) {
        oldCollectionId = _collectionNameToId[oldName]!;
      }
    }

    String newCollectionId = updatedPreset.collectionId;
    final newName = updatedPreset.collection.isNotEmpty ? updatedPreset.collection : 'Default';
    if (_collectionNameToId.containsKey(newName)) {
      newCollectionId = _collectionNameToId[newName]!;
    }

    // Create/overwrite the preset document in the new collection first
    await _addPresetToFirebase(updatedPreset);

    // Delete the old document if the collection actually changed and we know the old ID
    if (oldCollectionId.isNotEmpty && oldCollectionId != newCollectionId) {
      await deletePresetByIdFromCollection(updatedPreset.presetId, oldCollectionId);
    }

    // Update local cache saved already by callers; notify listeners if needed
    await _saveLocalCache();
    _notifyDataChanged();
  }

  // _deletePresetFromFirebase removed (deletion not used)

  /// Delete a preset document from a specific collection by IDs (used when moving between collections)
  Future<void> deletePresetByIdFromCollection(String presetId, String oldCollectionId) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    if (presetId.isEmpty || oldCollectionId.isEmpty) {
      return; // nothing to delete
    }

    try {
      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .doc(oldCollectionId)
          .collection('presets')
          .doc(presetId)
          .delete();
      print("🧹 Deleted old preset doc $presetId from collection $oldCollectionId after move");
    } catch (e) {
      print("❌ Failed to delete old preset $presetId from $oldCollectionId: $e");
    }
  }

  // Upload image to Firebase Storage
  Future<String> uploadImage(File imageFile, String presetId) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    final fileName = '${presetId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final ref = _storage.ref().child('users/${user.uid}/thumbnails/$fileName');

    try {
      await LogService.log('ThumbUpload:start presetId=$presetId file=${imageFile.path} target=$fileName');
      final uploadTask = ref.putFile(imageFile);
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();
      await LogService.log('ThumbUpload:success presetId=$presetId url=$downloadUrl');
      return downloadUrl;
    } catch (e) {
      await LogService.log('ThumbUpload:error presetId=$presetId -> $e');
      rethrow;
    }
  }

  /// Replace the generated image URL for a preset in Firebase and set it as latest thumbnail
  ///
  /// Previous behavior appended to an array and could lead to unintended document creation
  /// in some environments. We now perform a field-level update to replace the existing
  /// thumbnail URL without creating a new preset document.
  Future<void> appendGeneratedImageUrlToPreset(Preset preset, String imageUrl) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    // Resolve collectionId from name mapping if needed
    String collectionId = preset.collectionId;
    final desiredCollectionName = preset.collection.isNotEmpty ? preset.collection : 'Default';
    if (_collectionNameToId.containsKey(desiredCollectionName)) {
      collectionId = _collectionNameToId[desiredCollectionName]!;
    }
    if (collectionId.isEmpty) {
      collectionId = _generateCollectionId();
      await createCollectionInFirebase(desiredCollectionName, collectionId);
      _collectionNameToId[desiredCollectionName] = collectionId;
    }

    final docRef = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('collections')
        .doc(collectionId)
        .collection('presets')
        .doc(preset.presetId);

    try {
      await LogService.log('ThumbReplace:start presetId=${preset.presetId} collectionId=$collectionId url=$imageUrl');
      // Replace entire array with a single latest URL to maintain array type
      await docRef.update({
        'generatedImageUrls': [imageUrl],
        'thumbnailPath': imageUrl,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await LogService.log('ThumbReplace:success presetId=${preset.presetId}');
      // Local immediate update to refresh UI
      for (int i = 0; i < _localPresets.length; i++) {
        if (_localPresets[i].presetId == preset.presetId) {
          _localPresets[i] = _localPresets[i].copyWith(generatedImageUrls: imageUrl);
          break;
        }
      }
      for (int i = 0; i < _localPostDeliveryPresets.length; i++) {
        if (_localPostDeliveryPresets[i].presetId == preset.presetId) {
          _localPostDeliveryPresets[i] = _localPostDeliveryPresets[i].copyWith(generatedImageUrls: imageUrl);
          break;
        }
      }
      _notifyDataChanged();
    } catch (e) {
      await LogService.log('ThumbReplace:error presetId=${preset.presetId} -> $e');
      rethrow;
    }
  }

  // Get collections for dropdown
  List<String> getCollectionNames() {
    final collections = <String>[];
    for (final collection in _localCollections) {
      collections.add(collection.name);
    }
    collections.add('+ Create New Collection...');
    return collections;
  }

  // Generate unique preset ID
  String _generatePresetId() {
    return 'axnTBZpULDUYtjrL${DateTime.now().millisecondsSinceEpoch}';
  }

  // Generate unique collection ID
  String _generateCollectionId() {
    return 'TT7GnXQYcYQXCpwx${DateTime.now().millisecondsSinceEpoch}';
  }

  // Save to local cache
  Future<void> _saveLocalCache() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Save presets
    final presetsJson = _localPresets.map((p) => p.toJson()).toList();
    await prefs.setString('local_presets', jsonEncode(presetsJson));
    
    // Save collections
    final collectionsJson = _localCollections.map((c) => c.toJson()).toList();
    await prefs.setString('local_collections', jsonEncode(collectionsJson));
    
    // Save post-delivery presets
    final postDeliveryPresetsJson = _localPostDeliveryPresets.map((p) => p.toJson()).toList();
    await prefs.setString('local_post_delivery_presets', jsonEncode(postDeliveryPresetsJson));
    
    // Save post-delivery collections
    final postDeliveryCollectionsJson = _localPostDeliveryCollections.map((c) => c.toJson()).toList();
    await prefs.setString('local_post_delivery_collections', jsonEncode(postDeliveryCollectionsJson));
  }

  // Load from local cache
  Future<void> _loadFromLocalCache() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load presets
    final presetsString = prefs.getString('local_presets');
    if (presetsString != null) {
      final presetsJson = jsonDecode(presetsString) as List;
      _localPresets = presetsJson.map((json) => Preset.fromJson(json)).toList();
    }
    
    // Load collections
    final collectionsString = prefs.getString('local_collections');
    if (collectionsString != null) {
      final collectionsJson = jsonDecode(collectionsString) as List;
      _localCollections = collectionsJson.map((json) => Collection.fromJson(json)).toList();
    }
    
    // Load post-delivery presets
    final postDeliveryPresetsString = prefs.getString('local_post_delivery_presets');
    if (postDeliveryPresetsString != null) {
      final postDeliveryPresetsJson = jsonDecode(postDeliveryPresetsString) as List;
      _localPostDeliveryPresets = postDeliveryPresetsJson.map((json) => Preset.fromJson(json)).toList();
    }
    
    // Load post-delivery collections
    final postDeliveryCollectionsString = prefs.getString('local_post_delivery_collections');
    if (postDeliveryCollectionsString != null) {
      final postDeliveryCollectionsJson = jsonDecode(postDeliveryCollectionsString) as List;
      _localPostDeliveryCollections = postDeliveryCollectionsJson.map((json) => Collection.fromJson(json)).toList();
    }
  }

  // Switch data source (Live/Post Delivery)
  List<Preset> getPresetsForDataSource(String dataSource) {
    // Handle both 'live' and 'post' (or 'post-delivery')
    final isLive = dataSource == 'live';
    final presets = isLive ? _localPresets : _localPostDeliveryPresets;
    print("🔍 getPresetsForDataSource('$dataSource'): returning ${presets.length} presets");
    print("   Live presets: ${_localPresets.length}, Post-delivery presets: ${_localPostDeliveryPresets.length}");
    for (final preset in presets) {
      print("  - ${preset.title} (ID: ${preset.presetId}, collection: '${preset.collection}')");
    }
    return presets;
  }

  // Refresh data from Firebase (no longer needed to re-categorize since we fetch from separate paths)
  void recategorizePresets() {
    // Since we now fetch from separate paths, we just need to refresh from Firebase
    _loadUserDataFromFirebase();
  }

  // Get preset by index from the combined list for the current data source
  Preset? getPresetByIndex(int index, String dataSource) {
    final presets = getPresetsForDataSource(dataSource);
    if (index < 0 || index >= presets.length) return null;
    return presets[index];
  }

  List<Collection> getCollectionsForDataSource(String dataSource) {
    // Show ALL collections regardless of data source; de-duplicate by name
    final Map<String, Collection> nameToCollection = {};
    for (final c in _localCollections) {
      if (c.name.isNotEmpty) {
        nameToCollection.putIfAbsent(c.name, () => c);
      }
    }
    for (final c in _localPostDeliveryCollections) {
      if (c.name.isNotEmpty) {
        nameToCollection.putIfAbsent(c.name, () => c);
      }
    }
    final result = nameToCollection.values.toList();
    print("🔍 getCollectionsForDataSource('$dataSource'): returning ${result.length} collections");
    for (final collection in result) {
      print("   - '${collection.name}' (ID: ${collection.id})");
    }
    return result;
  }

  // Debounced save preset field to Firebase with conflict resolution
  void debouncedSavePresetFieldById(String presetId, String field, String value) {
    final preset = _getPresetById(presetId);
    if (preset == null) return;
    final timerKey = 'preset_${presetId}_$field';
    
    // Mark preset as being edited to prevent real-time overwrites
    _editingPresets.add(preset.presetId);
    
    // Cancel existing timer if any
    _debounceTimers[timerKey]?.cancel();
    
    // Create new timer with 2 second delay
    _debounceTimers[timerKey] = Timer(const Duration(seconds: 2), () {
      _performPresetFieldSaveById(presetId, field, value);
      _debounceTimers.remove(timerKey);
      // Remove from editing set after save
      _editingPresets.remove(presetId);
    });
  }

  // Perform the actual preset field save with retry logic and conflict resolution
  Future<void> _performPresetFieldSaveById(String presetId, String field, String value) async {
    final user = _authService.currentUser;
    if (user == null) return;

    final preset = _getPresetById(presetId);
    if (preset == null) return;
    final operationKey = '${presetId}_$field';
    
    // Update local preset with new timestamp and mark as local change
    final updatedPreset = preset.copyWith(
      lastModified: DateTime.now().millisecondsSinceEpoch,
      isLocalChange: true,
    );
    
    // Update in the correct local list by id
    for (int i = 0; i < _localPresets.length; i++) {
      if (_localPresets[i].presetId == presetId) {
        _localPresets[i] = updatedPreset;
        break;
      }
    }
    for (int i = 0; i < _localPostDeliveryPresets.length; i++) {
      if (_localPostDeliveryPresets[i].presetId == presetId) {
        _localPostDeliveryPresets[i] = updatedPreset;
        break;
      }
    }
    
    // Always update local cache first
    await _saveLocalCache();
    
    // Try to sync to Firebase with retry logic
    await _syncPresetFieldWithRetry(updatedPreset, field, value, operationKey);
  }

  // Sync preset field with retry logic
  Future<void> _syncPresetFieldWithRetry(Preset preset, String field, String value, String operationKey) async {
    final retryCount = _retryCounts[operationKey] ?? 0;
    
    try {
      // Ensure preset exists in Firebase first
      await _ensurePresetExistsInFirebase(preset);
      
      // Map field names to Firebase field names
      final firebaseFieldMap = {
        "name": "title",
        "url": "postProcessingUrl",
        "collection": "collectionId",
      };
      
      final firebaseField = firebaseFieldMap[field] ?? field;
      
      // Use field-level update with timestamp
      final success = await _updatePresetFieldInFirebase(preset, firebaseField, value);
      
      if (success) {
        print("✅ Field '$field' for preset '${preset.title}' synced to Firebase");
        // Reset retry count on success
        _retryCounts.remove(operationKey);
      } else {
        throw Exception("Firebase update failed");
      }
    } catch (e) {
      print("⚠️ Firebase sync failed for field '$field' (attempt ${retryCount + 1}): $e");
      
      if (retryCount < _maxRetries) {
        // Retry with exponential backoff
        _retryCounts[operationKey] = retryCount + 1;
        final delay = Duration(milliseconds: 1000 * (retryCount + 1));
        
        Timer(delay, () {
          _syncPresetFieldWithRetry(preset, field, value, operationKey);
        });
      } else {
        print("❌ Max retries reached for field '$field', saved locally only");
        _retryCounts.remove(operationKey);
      }
    }
  }

  // Ensure preset exists in Firebase - exactly like legacy app
  Future<void> _ensurePresetExistsInFirebase(Preset preset) async {
    try {
      await _addPresetToFirebase(preset);
    } catch (e) {
      // Preset might already exist, that's OK
      print("Preset might already exist in Firebase: $e");
    }
  }

  // Update preset field in Firebase with correct paths for Live vs Post-Delivery
  Future<bool> _updatePresetFieldInFirebase(Preset preset, String field, String value) async {
    try {
      final user = _authService.currentUser;
      if (user == null) return false;

      // Unified path for all presets (use collectionId regardless of data source)
      String collectionId = preset.collectionId;
      if (collectionId.isEmpty) {
        collectionId = _generateCollectionId();
      }
      final docRef = _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .doc(collectionId)
          .collection('presets')
          .doc(preset.presetId);

      // Update only the specific field with timestamp - field-level update
      await docRef.update({
        field: value,
        'lastModified': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });

      // updated
      return true;
    } catch (e) {
      print("❌ Error updating preset field in Firebase: $e");
      return false;
    }
  }

  // ===== REAL-TIME FIREBASE LISTENERS =====
  
  /// Start real-time Firebase listeners for constant data syncing
  Future<void> _startRealtimeListeners() async {
    final user = _authService.currentUser;
    if (user == null || _isListening) return;

    print("🔄 Starting real-time Firebase listeners...");
    _isListening = true;

    try {
      // Listen to collections changes
      _collectionsListener = _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .snapshots()
          .listen(
            _onCollectionsChanged,
            onError: (error) {
              print("❌ Collections listener error: $error");
            },
          );

      // Listen to presets changes (we'll need to listen to all collections)
      await _startPresetsListeners();

      print("✅ Real-time Firebase listeners started successfully");
    } catch (e) {
      print("❌ Error starting real-time listeners: $e");
      _isListening = false;
    }
  }

  /// Start presets listeners for current data source
  Future<void> _startPresetsListeners() async {
    final user = _authService.currentUser;
    if (user == null) return;

    // Cancel existing presets listener
    await _presetsListener?.cancel();
    
    // Reset the initial listener fire flag when starting new listeners
    _isInitialListenerFire = true;

    // All presets are now in the same path, so we always listen to collections
    _startLivePresetsListener();
  }

  /// Start Live presets listener (listens to all collections and their presets)
  Future<void> _startLivePresetsListener() async {
    final user = _authService.currentUser;
    if (user == null) return;

    // First, get all collections for this user
    _firestore
        .collection('users')
        .doc(user.uid)
        .collection('collections')
        .snapshots()
        .listen((collectionsSnapshot) async {
      // For each collection, listen to its presets
      final List<Preset> allPresets = [];
      
      for (final collectionDoc in collectionsSnapshot.docs) {
        final collectionId = collectionDoc.id;
        final collectionData = collectionDoc.data();
        final collectionName = (collectionData is Map<String, dynamic>)
            ? (collectionData['name'] ?? 'Default')
            : 'Default';

        // Track mapping for future writes
        _collectionNameToId[collectionName] = collectionId;
        
        // Fetch presets for this collection
        final presetsSnapshot = await _firestore
            .collection('users')
            .doc(user.uid)
            .collection('collections')
            .doc(collectionId)
            .collection('presets')
            .get();
        
        for (final presetDoc in presetsSnapshot.docs) {
          final data = presetDoc.data();
          final preset = Preset.fromMap({
            ...data,
            'presetId': presetDoc.id,
            'collectionId': collectionId,
            'collection': collectionName,
            'prompt': (data['prompt'] ?? ''),
          });
          allPresets.add(preset);
        }
      }
      
      // Update local presets - merge instead of replace to preserve local deletions
      _mergePresetsFromFirebase(allPresets);
      _saveLocalCache();
      _notifyDataChanged();
      
      // live presets updated
    });
  }

  /// Helper method to determine presetType from a preset
  String _getPresetTypeFromPreset(Preset preset) {
    // Check the postProcessingUrl to determine type
    if (preset.postProcessingUrl.toLowerCase().contains('post-delivery')) {
      return 'post-delivery';
    } else if (preset.postProcessingUrl.toLowerCase().contains('nano-banana')) {
      return 'nano-banana';
    }
    // Default to nano-banana if unclear
    return 'nano-banana';
  }

  /// Merge presets from Firebase with conflict resolution
  void _mergePresetsFromFirebase(List<Preset> firebasePresets) {
    // Don't merge if any presets are currently being edited
    if (_editingPresets.isNotEmpty) {
      print("🔄 Skipping merge - presets are being edited: $_editingPresets");
      return;
    }
    
    // Create maps for efficient lookup
    final localPresetsMap = <String, Preset>{};
    final firebasePresetsMap = <String, Preset>{};
    
    for (final preset in _localPresets) {
      if (preset.presetId.isNotEmpty) {
        localPresetsMap[preset.presetId] = preset;
      }
    }
    
    for (final preset in firebasePresets) {
      if (preset.presetId.isNotEmpty) {
        firebasePresetsMap[preset.presetId] = preset;
      }
    }
    
    // Merge strategy with conflict resolution
    final mergedPresets = <Preset>[];
    
    // Process all presets (both local and Firebase)
    final allPresetIds = <String>{};
    allPresetIds.addAll(localPresetsMap.keys);
    allPresetIds.addAll(firebasePresetsMap.keys);
    
    for (final presetId in allPresetIds) {
      final localPreset = localPresetsMap[presetId];
      final firebasePreset = firebasePresetsMap[presetId];
      
      if (localPreset != null && firebasePreset != null) {
        // Both exist - use conflict resolution
        if (localPreset.isLocalChange && localPreset.lastModified > firebasePreset.lastModified) {
          // Local change is newer - keep local version
          mergedPresets.add(localPreset);
          print("🔄 Conflict resolved: keeping local version of preset '$presetId'");
        } else {
          // Firebase version is newer or no local changes - use Firebase version
          mergedPresets.add(firebasePreset);
        }
      } else if (localPreset != null) {
        // Only exists locally - keep it (might be deleted from Firebase)
        mergedPresets.add(localPreset);
      } else if (firebasePreset != null) {
        // Only exists in Firebase - add it
        mergedPresets.add(firebasePreset);
      }
    }
    
    // Re-categorize merged presets by presetType
    _localPresets.clear();
    _localPostDeliveryPresets.clear();
    
    for (final preset in mergedPresets) {
      // Determine presetType from the preset's URL or other indicators
      final presetType = _getPresetTypeFromPreset(preset);
      
      if (presetType == 'post-delivery') {
        _localPostDeliveryPresets.add(preset);
      } else {
        _localPresets.add(preset);
      }
    }
    
    print("🔄 Merged presets with conflict resolution: ${mergedPresets.length} total");
    print("   Re-categorized: ${_localPresets.length} live, ${_localPostDeliveryPresets.length} post-delivery");
  }

  /// Merge post-delivery presets from Firebase with conflict resolution
  void _mergePostDeliveryPresetsFromFirebase(List<Preset> firebasePresets) {
    // Don't merge if any presets are currently being edited
    if (_editingPresets.isNotEmpty) {
      print("🔄 Skipping post-delivery merge - presets are being edited: $_editingPresets");
      return;
    }
    
    // Create maps for efficient lookup
    final localPresetsMap = <String, Preset>{};
    final firebasePresetsMap = <String, Preset>{};
    
    for (final preset in _localPostDeliveryPresets) {
      if (preset.presetId.isNotEmpty) {
        localPresetsMap[preset.presetId] = preset;
      }
    }
    
    for (final preset in firebasePresets) {
      if (preset.presetId.isNotEmpty) {
        firebasePresetsMap[preset.presetId] = preset;
      }
    }
    
    // Merge strategy with conflict resolution
    final mergedPresets = <Preset>[];
    
    // Process all presets (both local and Firebase)
    final allPresetIds = <String>{};
    allPresetIds.addAll(localPresetsMap.keys);
    allPresetIds.addAll(firebasePresetsMap.keys);
    
    for (final presetId in allPresetIds) {
      final localPreset = localPresetsMap[presetId];
      final firebasePreset = firebasePresetsMap[presetId];
      
      if (localPreset != null && firebasePreset != null) {
        // Both exist - use conflict resolution
        if (localPreset.isLocalChange && localPreset.lastModified > firebasePreset.lastModified) {
          // Local change is newer - keep local version
          mergedPresets.add(localPreset);
          print("🔄 Post-delivery conflict resolved: keeping local version of preset '$presetId'");
        } else {
          // Firebase version is newer or no local changes - use Firebase version
          mergedPresets.add(firebasePreset);
        }
      } else if (localPreset != null) {
        // Only exists locally - keep it
        mergedPresets.add(localPreset);
      } else if (firebasePreset != null) {
        // Only exists in Firebase - add it
        mergedPresets.add(firebasePreset);
      }
    }
    
    _localPostDeliveryPresets = mergedPresets;
    print("🔄 Merged post-delivery presets with conflict resolution: ${mergedPresets.length} total");
  }

  /// Merge local changes with Firebase data during sync - exactly like legacy app
  void _mergeLocalChangesWithFirebaseData(List<Preset> currentLocalPresets, List<Collection> currentLocalCollections) {
    // Create maps for efficient lookup
    final firebasePresetsMap = <String, Preset>{};
    final firebaseCollectionsMap = <String, Collection>{};
    
    for (final preset in _localPresets) {
      if (preset.presetId.isNotEmpty) {
        firebasePresetsMap[preset.presetId] = preset;
      }
    }
    
    for (final collection in _localCollections) {
      if (collection.name.isNotEmpty) {
        firebaseCollectionsMap[collection.name] = collection;
      }
    }
    
    // Merge strategy: preserve local changes that are not in Firebase
    final mergedPresets = <Preset>[];
    final mergedCollections = <Collection>[];
    
    // Add all Firebase presets
    mergedPresets.addAll(_localPresets);
    
    // Add local presets that are not in Firebase (preserve local deletions/edits)
    for (final localPreset in currentLocalPresets) {
      if (localPreset.presetId.isNotEmpty && !firebasePresetsMap.containsKey(localPreset.presetId)) {
        // This preset exists locally but not in Firebase - keep it (it was deleted from Firebase)
        mergedPresets.add(localPreset);
      }
    }
    
    // Add all Firebase collections
    mergedCollections.addAll(_localCollections);
    
    // Add local collections that are not in Firebase
    for (final localCollection in currentLocalCollections) {
      if (localCollection.name.isNotEmpty && !firebaseCollectionsMap.containsKey(localCollection.name)) {
        mergedCollections.add(localCollection);
      }
    }
    
    _localPresets = mergedPresets;
    _localCollections = mergedCollections;
    
    print("🔄 Merged local changes with Firebase data: ${mergedPresets.length} presets, ${mergedCollections.length} collections");
  }

  /// Handle collections changes from real-time listener
  void _onCollectionsChanged(QuerySnapshot snapshot) {
    print("📡 Collections changed - processing ${snapshot.docs.length} collections");
    
    try {
      final newCollections = <Collection>[];
      
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final collection = Collection.fromMap({
          'id': doc.id,
          ...data,
        });
        newCollections.add(collection);
      }

      // Update local cache based on data source
      if (_dataSource == 'live') {
        _localCollections = newCollections;
      } else {
        _localPostDeliveryCollections = newCollections;
      }

      // Save to local cache
      _saveLocalCache();

      // Notify AppState of changes
      _notifyDataChanged();

      print("✅ Collections updated from real-time listener: ${newCollections.length} items");
    } catch (e) {
      print("❌ Error processing collections change: $e");
    }
  }

  /// Handle presets changes from real-time listener
  void _onPresetsChanged(List<Preset> allPresets) {
    print("📡 Presets changed - processing ${allPresets.length} presets");
    
    // Skip merging on initial listener fire since we already fetched data during initialization
    if (_isInitialListenerFire) {
      print("🔄 Skipping initial listener fire - data already loaded during initialization");
      _isInitialListenerFire = false;
      return;
    }
    
    try {
      // Categorize presets by presetType
      final livePresets = <Preset>[];
      final postDeliveryPresets = <Preset>[];
      
      for (final preset in allPresets) {
        // We need to get the presetType from Firebase data
        // Since we don't have direct access to the raw data here, we'll need to refetch
        // For now, let's trigger a full refresh
        _loadUserDataFromFirebase();
        return;
      }

      // Save to local cache
      _saveLocalCache();

      // Notify AppState of changes
      _notifyDataChanged();

      print("✅ Presets updated from real-time listener: ${allPresets.length} items");
    } catch (e) {
      print("❌ Error processing presets change: $e");
    }
  }

  /// Stop real-time Firebase listeners
  Future<void> stopRealtimeListeners() async {
    print("🛑 Stopping real-time Firebase listeners...");
    
    await _collectionsListener?.cancel();
    await _presetsListener?.cancel();
    
    _collectionsListener = null;
    _presetsListener = null;
    _isListening = false;
    
    print("✅ Real-time Firebase listeners stopped");
  }

  /// Check if real-time listeners are active
  bool get isListening => _isListening;

  /// Restart listeners (useful when user changes or data source changes)
  Future<void> restartListeners() async {
    await stopRealtimeListeners();
    await _startRealtimeListeners();
  }

  /// Set callback for notifying AppState of data changes
  void setDataChangedCallback(VoidCallback callback) {
    _onDataChanged = callback;
  }

  /// Notify AppState of data changes
  void _notifyDataChanged() {
    _onDataChanged?.call();
  }

  /// Update data source and restart listeners
  void updateDataSource(String dataSource) {
    _dataSource = dataSource;
    if (_isListening) {
      restartListeners();
    }
  }
}
