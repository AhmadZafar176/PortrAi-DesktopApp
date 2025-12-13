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

  List<Preset> _localPresets = [];
  List<Collection> _localCollections = [];
  List<Preset> _localPostDeliveryPresets = [];
  List<Collection> _localPostDeliveryCollections = [];

  final Map<String, String> _collectionNameToId = {};

  bool _presetsLoadedFromFirebase = false;
  bool _collectionsLoadedFromFirebase = false;
  bool _postDeliveryPresetsLoadedFromFirebase = false;
  bool _postDeliveryCollectionsLoadedFromFirebase = false;
  DateTime? _lastFirebaseSync;
  static const Duration _firebaseSyncInterval = Duration(minutes: 5);
  bool _initialSyncCompleted = false;
  bool _isInitialListenerFire = true;
  String? _currentUserId; // Track current user to detect user changes

  final Map<String, Timer> _debounceTimers = {};

  StreamSubscription<QuerySnapshot>? _collectionsListener;
  StreamSubscription<QuerySnapshot>? _presetsListener;
  bool _isListening = false;

  final Set<String> _editingPresets = <String>{};
  final Map<String, int> _retryCounts = <String, int>{};
  static const int _maxRetries = 3;

  VoidCallback? _onDataChanged;

  String _dataSource = 'live';

  List<Preset> get localPresets => _localPresets;
  List<Collection> get localCollections => _localCollections;
  List<Preset> get localPostDeliveryPresets => _localPostDeliveryPresets;
  List<Collection> get localPostDeliveryCollections => _localPostDeliveryCollections;

  Future<void> initialize() async {

    print('PresetService:initialize');
    
    // Check for user change BEFORE loading cache to avoid loading wrong user's data
    final user = _authService.currentUser;
    if (user == null) {
      // No user signed in, clear everything
      _currentUserId = null;
      _localPresets.clear();
      _localCollections.clear();
      _localPostDeliveryPresets.clear();
      _localPostDeliveryCollections.clear();
      return;
    }
    
    // Check if user has changed - if so, clear everything first
    final userChanged = _currentUserId != null && _currentUserId != user.uid;
    if (userChanged) {
      print("🔄 User changed from '$_currentUserId' to '${user.uid}', clearing old data");
      // Stop old listeners before switching users
      await stopRealtimeListeners();
      _initialSyncCompleted = false;
      _lastFirebaseSync = null;
      _currentUserId = user.uid;
      // Clear local data when user changes - don't load old cache
      _localPresets.clear();
      _localCollections.clear();
      _localPostDeliveryPresets.clear();
      _localPostDeliveryCollections.clear();
    } else if (_currentUserId == null) {
      // First time setting user
      _currentUserId = user.uid;
    }
    
    // Only load cache if user hasn't changed (to avoid loading wrong user's data)
    if (!userChanged) {
      await _loadFromLocalCache();
      print("📁 Loaded data from local cache");
    } else {
      print("📁 Skipping cache load - user changed, will fetch fresh data");
    }
    
    await _loadUserDataFromFirebase();
    
    // Start listeners - if permission denied, retry after a delay
    await _startRealtimeListeners();
    
    // If listeners didn't start due to permission error, retry after a delay
    // This handles cases where Firebase Auth token hasn't propagated yet
    if (!_isListening) {
      print("⏳ Waiting before retrying listener setup...");
      await Future.delayed(const Duration(seconds: 2));
      final retryUser = _authService.currentUser;
      if (retryUser != null && retryUser.uid == user.uid) {
        print("🔄 Retrying listener setup...");
        await _startRealtimeListeners();
      }
    }
  }

  Future<void> _loadUserDataFromFirebase() async {
    final user = _authService.currentUser;
    if (user == null) return;

    final currentTime = DateTime.now();
    
    // Verify user hasn't changed (should already be checked in initialize, but double-check)
    if (_currentUserId != null && _currentUserId != user.uid) {
      print("⚠️ User mismatch detected in _loadUserDataFromFirebase - aborting");
      return;
    }
    
    if (_currentUserId == null) {
      _currentUserId = user.uid;
    }

    // Force sync if initial sync not completed (includes user change case), otherwise check if sync is needed
    final needsSync = !_initialSyncCompleted || 
                     _lastFirebaseSync == null ||
                     currentTime.difference(_lastFirebaseSync!) > _firebaseSyncInterval;

    if (needsSync) {
      print("🔄 Performing Firebase sync...");
      await _performFirebaseSync();
      _initialSyncCompleted = true;
      _lastFirebaseSync = currentTime;
      await LogService.log('PresetService: Firebase sync complete');
      // Notify that data has changed so UI can refresh
      _notifyDataChanged();
    } else {
      print("🚀 Using cached data, Firebase sync not needed");
      // Even if using cache, notify to ensure UI is updated
      _notifyDataChanged();
    }
  }

  Future<void> _performFirebaseSync() async {
    try {
      final currentLocalPresets = List<Preset>.from(_localPresets);
      final currentLocalCollections = List<Collection>.from(_localCollections);

      await _fetchUserPresets();
      await _fetchUserCollections();

      _mergeLocalChangesWithFirebaseData(currentLocalPresets, currentLocalCollections);
      
      await _saveLocalCache();
      print("✅ Firebase sync completed successfully");
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("⚠️ Permission denied during sync - user may not be fully authenticated yet: $e");
        // Don't throw - use local cache
      } else if (errorString.contains('internal') || 
                 errorString.contains('server error')) {
        print("⚠️ Internal server error during sync - user document may not exist yet (normal for new users): $e");
        // Don't throw - use local cache (which will be empty for new users)
      } else {
        print("❌ Firebase sync failed: $e, using local cache");
      }
      // Never throw - always use local cache as fallback
    }
  }

  Future<void> _fetchUserPresets() async {
    final user = _authService.currentUser;
    if (user == null) return;

    try {
      _localPresets.clear();
      _localPostDeliveryPresets.clear();

      await _fetchAllPresetsFromCollections(user.uid);

      _presetsLoadedFromFirebase = true;
      print("✅ Loaded ${_localPresets.length} live presets and ${_localPostDeliveryPresets.length} post-delivery presets");
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("⚠️ Permission denied fetching presets - user may not be fully authenticated yet: $e");
        // Don't throw - this will be retried when listeners start
      } else {
        print("❌ Error fetching presets: $e");
      }
    }
  }

  Future<void> _fetchAllPresetsFromCollections(String userId) async {
    try {
      // First check if user document exists - if not, user is new and has no data
      final userDocRef = _firestore.collection('users').doc(userId);
      final userDocSnapshot = await userDocRef.get();
      
      if (!userDocSnapshot.exists) {
        print("📁 User document doesn't exist yet - this is normal for new users");
        _localPresets.clear();
        _localPostDeliveryPresets.clear();
        return;
      }
      
      final collectionsSnapshot = await userDocRef.collection('collections').get();
      
      // If no collections exist, that's fine - user just hasn't created any yet
      if (collectionsSnapshot.docs.isEmpty) {
        print("📁 No collections found for user - this is normal for new users");
        _localPresets.clear();
        _localPostDeliveryPresets.clear();
        return;
      }

      for (final collectionDoc in collectionsSnapshot.docs) {
        final collectionData = collectionDoc.data();
        final collectionName = collectionData['name'] ?? 'Default';
        final collectionId = collectionDoc.id;
        
        print("🔍 Fetching presets from collection: $collectionName");

        final presetsSnapshot = await collectionDoc.reference.collection('presets').get();
        
        for (final presetDoc in presetsSnapshot.docs) {
          final presetData = presetDoc.data();

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

          final presetType = presetData['presetType'] ?? 'nano-banana';
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

  Future<void> _fetchUserCollections() async {
    final user = _authService.currentUser;
    if (user == null) return;

    try {
      _localCollections.clear();
      _localPostDeliveryCollections.clear();

      await _fetchAllCollections(user.uid);

      await _categorizeCollectionsByPresetType();

      _collectionsLoadedFromFirebase = true;
      print("✅ Loaded ${_localCollections.length} live collections and ${_localPostDeliveryCollections.length} post-delivery collections");
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("⚠️ Permission denied fetching collections - user may not be fully authenticated yet: $e");
        // Don't throw - this will be retried when listeners start
      } else {
        print("❌ Error fetching collections: $e");
      }
    }
  }

  Future<void> _fetchAllCollections(String userId) async {
    try {
      // First check if user document exists - if not, user is new and has no data
      final userDocRef = _firestore.collection('users').doc(userId);
      final userDocSnapshot = await userDocRef.get();
      
      if (!userDocSnapshot.exists) {
        print("📁 User document doesn't exist yet - this is normal for new users");
        _localCollections.clear();
        _localPostDeliveryCollections.clear();
        return;
      }
      
      final collectionsSnapshot = await userDocRef.collection('collections').get();
      
      // Clear existing collections before adding new ones
      _localCollections.clear();
      _localPostDeliveryCollections.clear();

      for (final doc in collectionsSnapshot.docs) {
        final data = doc.data();
        final collection = Collection(
          id: doc.id,
          name: data['name'] ?? 'Default',
          description: data['description'] ?? '',
        );

        _localCollections.add(collection);
        _localPostDeliveryCollections.add(collection);
      }
      
      print("✅ Fetched ${_localCollections.length} collections from Firebase");
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("⚠️ Permission denied fetching collections - user may not be fully authenticated yet: $e");
        // Return empty list - user document might not exist yet or auth not ready
        _localCollections.clear();
        _localPostDeliveryCollections.clear();
      } else {
        print("❌ Error fetching collections: $e");
      }
    }
  }

  Future<void> _categorizeCollectionsByPresetType() async {
    try {

      _localCollections.clear();
      _localPostDeliveryCollections.clear();

      final Set<String> liveCollectionNames = {};
      for (final preset in _localPresets) {
        if (preset.collection.isNotEmpty) {
          liveCollectionNames.add(preset.collection);
        }
      }

      final Set<String> postDeliveryCollectionNames = {};
      for (final preset in _localPostDeliveryPresets) {
        if (preset.collection.isNotEmpty) {
          postDeliveryCollectionNames.add(preset.collection);
        }
      }

      for (final collectionName in liveCollectionNames) {
        final liveCollection = Collection(
          id: 'live-$collectionName',
          name: collectionName,
          description: 'Live collection for $collectionName',
        );
        _localCollections.add(liveCollection);
      }

      for (final collectionName in postDeliveryCollectionNames) {
        final postDeliveryCollection = Collection(
          id: 'post-delivery-$collectionName',
          name: collectionName,
          description: 'Post-Delivery collection for $collectionName',
        );
        _localPostDeliveryCollections.add(postDeliveryCollection);
      }

    } catch (e) {
      print("❌ Error categorizing collections: $e");
    }
  }

  Future<void> createCollectionInFirebase(String collectionName, String collectionId) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    try {

      final collectionData = {
        'name': collectionName,
        'description': '$collectionName collection',
        'createdAt': DateTime.now().millisecondsSinceEpoch.toString(),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };

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


  int _findPresetIndex(String presetId) {

    for (int i = 0; i < _localPresets.length; i++) {
      if (_localPresets[i].presetId == presetId) {
        return i;
      }
    }

    for (int i = 0; i < _localPostDeliveryPresets.length; i++) {
      if (_localPostDeliveryPresets[i].presetId == presetId) {
        return i + _localPresets.length;
      }
    }
    return -1;
  }

  Preset? _getPresetById(String presetId) {

    for (final preset in _localPresets) {
      if (preset.presetId == presetId) {
        return preset;
      }
    }

    for (final preset in _localPostDeliveryPresets) {
      if (preset.presetId == presetId) {
        return preset;
      }
    }
    return null;
  }

  Future<void> updatePreset(int index, Preset updatedPreset) async {

    final currentPreset = getPresetByIndex(index, _dataSource);
    if (currentPreset == null) return;
    
    final presetId = currentPreset.presetId;
    if (presetId.isEmpty) return;

    for (int i = 0; i < _localPresets.length; i++) {
      if (_localPresets[i].presetId == presetId) {
        _localPresets[i] = updatedPreset;
        await _saveLocalCache();
        break;
      }
    }

    for (int i = 0; i < _localPostDeliveryPresets.length; i++) {
      if (_localPostDeliveryPresets[i].presetId == presetId) {
        _localPostDeliveryPresets[i] = updatedPreset;
        await _saveLocalCache();
        break;
      }
    }

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

  Future<void> deletePreset(int index) async {

    final presetToDelete = getPresetByIndex(index, _dataSource);
    if (presetToDelete == null) return;
    
    final presetId = presetToDelete.presetId;
    if (presetId.isEmpty) return;

    _localPresets.removeWhere((preset) => preset.presetId == presetId);

    _localPostDeliveryPresets.removeWhere((preset) => preset.presetId == presetId);
    
    await _saveLocalCache();


  }

  Future<void> _addPresetToFirebase(Preset preset) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    final collectionName = preset.collection.isNotEmpty ? preset.collection : 'Default';

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

    final presetType = _dataSource == 'live' ? 'nano-banana' : 'post-delivery';

    final presetData = {
      'presetId': preset.presetId,
      'title': preset.title.isNotEmpty ? preset.title : preset.name,
      'generatedImageUrls': preset.generatedImageUrls,
      'postProcessingUrl': preset.postProcessingUrl,
      'createdAt': preset.createdAt.isNotEmpty ? preset.createdAt : DateTime.now().millisecondsSinceEpoch.toString(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'presetType': presetType,
      'collectionId': collectionId,
      'collection': collectionName,
    };

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

  Future<void> _updatePresetInFirebase(Preset preset) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    final collectionName = preset.collection.isNotEmpty ? preset.collection : 'Default';

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

    final presetType = _dataSource == 'live' ? 'nano-banana' : 'post-delivery';

    final presetData = {
      'collectionId': collectionId,
      'presetId': preset.presetId,
      'title': preset.title.isNotEmpty ? preset.title : preset.name,
      'generatedImageUrls': preset.generatedImageUrls,
      'postProcessingUrl': preset.postProcessingUrl,
      'createdAt': preset.createdAt.isNotEmpty ? preset.createdAt : DateTime.now().millisecondsSinceEpoch.toString(),
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'presetType': presetType,
      'collection': collectionName,
    };

    await _firestore
        .collection('users')
        .doc(user.uid)
        .collection('collections')
        .doc(collectionId)
        .collection('presets')
        .doc(preset.presetId)
        .update(presetData);
  }

  Future<void> movePresetBetweenCollections({
    required Preset originalPreset,
    required Preset updatedPreset,
  }) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    String oldCollectionId = originalPreset.collectionId;
    if (oldCollectionId.isEmpty) {

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

    await _addPresetToFirebase(updatedPreset);

    if (oldCollectionId.isNotEmpty && oldCollectionId != newCollectionId) {
      await deletePresetByIdFromCollection(updatedPreset.presetId, oldCollectionId);
    }

    await _saveLocalCache();
    _notifyDataChanged();
  }


  Future<void> deletePresetByIdFromCollection(String presetId, String oldCollectionId) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

    if (presetId.isEmpty || oldCollectionId.isEmpty) {
      return;
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





  Future<void> appendGeneratedImageUrlToPreset(Preset preset, String imageUrl) async {
    final user = _authService.currentUser;
    if (user == null) throw Exception("User not authenticated");

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

      await docRef.update({
        'generatedImageUrls': [imageUrl],
        'thumbnailPath': imageUrl,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await LogService.log('ThumbReplace:success presetId=${preset.presetId}');

      for (int i = 0; i < _localPresets.length; i++) {
        if (_localPresets[i].presetId == preset.presetId) {
          _localPresets[i] = _localPresets[i].copyWith(
            generatedImageUrls: imageUrl,
            thumbnailPath: imageUrl,
          );
          break;
        }
      }
      for (int i = 0; i < _localPostDeliveryPresets.length; i++) {
        if (_localPostDeliveryPresets[i].presetId == preset.presetId) {
          _localPostDeliveryPresets[i] = _localPostDeliveryPresets[i].copyWith(
            generatedImageUrls: imageUrl,
            thumbnailPath: imageUrl,
          );
          break;
        }
      }
      _notifyDataChanged();
    } catch (e) {
      await LogService.log('ThumbReplace:error presetId=${preset.presetId} -> $e');
      rethrow;
    }
  }

  List<String> getCollectionNames() {
    final collections = <String>[];
    for (final collection in _localCollections) {
      collections.add(collection.name);
    }
    collections.add('+ Create New Collection...');
    return collections;
  }

  String _generatePresetId() {
    return 'axnTBZpULDUYtjrL${DateTime.now().millisecondsSinceEpoch}';
  }

  String _generateCollectionId() {
    return 'TT7GnXQYcYQXCpwx${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _saveLocalCache() async {
    final prefs = await SharedPreferences.getInstance();

    final presetsJson = _localPresets.map((p) => p.toJson()).toList();
    await prefs.setString('local_presets', jsonEncode(presetsJson));

    final collectionsJson = _localCollections.map((c) => c.toJson()).toList();
    await prefs.setString('local_collections', jsonEncode(collectionsJson));

    final postDeliveryPresetsJson = _localPostDeliveryPresets.map((p) => p.toJson()).toList();
    await prefs.setString('local_post_delivery_presets', jsonEncode(postDeliveryPresetsJson));

    final postDeliveryCollectionsJson = _localPostDeliveryCollections.map((c) => c.toJson()).toList();
    await prefs.setString('local_post_delivery_collections', jsonEncode(postDeliveryCollectionsJson));
  }

  Future<void> _loadFromLocalCache() async {
    final prefs = await SharedPreferences.getInstance();

    final presetsString = prefs.getString('local_presets');
    if (presetsString != null) {
      final presetsJson = jsonDecode(presetsString) as List;
      _localPresets = presetsJson.map((json) => Preset.fromJson(json)).toList();
    }

    final collectionsString = prefs.getString('local_collections');
    if (collectionsString != null) {
      final collectionsJson = jsonDecode(collectionsString) as List;
      _localCollections = collectionsJson.map((json) => Collection.fromJson(json)).toList();
    }

    final postDeliveryPresetsString = prefs.getString('local_post_delivery_presets');
    if (postDeliveryPresetsString != null) {
      final postDeliveryPresetsJson = jsonDecode(postDeliveryPresetsString) as List;
      _localPostDeliveryPresets = postDeliveryPresetsJson.map((json) => Preset.fromJson(json)).toList();
    }

    final postDeliveryCollectionsString = prefs.getString('local_post_delivery_collections');
    if (postDeliveryCollectionsString != null) {
      final postDeliveryCollectionsJson = jsonDecode(postDeliveryCollectionsString) as List;
      _localPostDeliveryCollections = postDeliveryCollectionsJson.map((json) => Collection.fromJson(json)).toList();
    }
  }

  Future<void> _clearLocalCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('local_presets');
      await prefs.remove('local_collections');
      await prefs.remove('local_post_delivery_presets');
      await prefs.remove('local_post_delivery_collections');
      print('✅ Cleared SharedPreferences cache');
    } catch (e) {
      print('❌ Failed to clear SharedPreferences cache: $e');
    }
  }

  List<Preset> getPresetsForDataSource(String dataSource) {

    final isLive = dataSource == 'live';
    final presets = isLive ? _localPresets : _localPostDeliveryPresets;
    print("🔍 getPresetsForDataSource('$dataSource'): returning ${presets.length} presets");
    print("   Live presets: ${_localPresets.length}, Post-delivery presets: ${_localPostDeliveryPresets.length}");
    for (final preset in presets) {
      print("  - ${preset.title} (ID: ${preset.presetId}, collection: '${preset.collection}')");
    }
    return presets;
  }

  void recategorizePresets() {

    _loadUserDataFromFirebase();
  }

  Preset? getPresetByIndex(int index, String dataSource) {
    final presets = getPresetsForDataSource(dataSource);
    if (index < 0 || index >= presets.length) return null;
    return presets[index];
  }

  List<Collection> getCollectionsForDataSource(String dataSource) {

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

  void debouncedSavePresetFieldById(String presetId, String field, String value) {
    final preset = _getPresetById(presetId);
    if (preset == null) return;
    final timerKey = 'preset_${presetId}_$field';

    _editingPresets.add(preset.presetId);

    _debounceTimers[timerKey]?.cancel();

    _debounceTimers[timerKey] = Timer(const Duration(seconds: 2), () {
      _performPresetFieldSaveById(presetId, field, value);
      _debounceTimers.remove(timerKey);

      _editingPresets.remove(presetId);
    });
  }

  Future<void> _performPresetFieldSaveById(String presetId, String field, String value) async {
    final user = _authService.currentUser;
    if (user == null) return;

    final preset = _getPresetById(presetId);
    if (preset == null) return;
    final operationKey = '${presetId}_$field';

    final updatedPreset = preset.copyWith(
      lastModified: DateTime.now().millisecondsSinceEpoch,
      isLocalChange: true,
    );

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

    await _saveLocalCache();

    await _syncPresetFieldWithRetry(updatedPreset, field, value, operationKey);
  }

  Future<void> _syncPresetFieldWithRetry(Preset preset, String field, String value, String operationKey) async {
    final retryCount = _retryCounts[operationKey] ?? 0;
    
    try {

      await _ensurePresetExistsInFirebase(preset);

      final firebaseFieldMap = {
        "name": "title",
        "url": "postProcessingUrl",
        "collection": "collectionId",
      };
      
      final firebaseField = firebaseFieldMap[field] ?? field;

      final success = await _updatePresetFieldInFirebase(preset, firebaseField, value);
      
      if (success) {
        print("✅ Field '$field' for preset '${preset.title}' synced to Firebase");

        _retryCounts.remove(operationKey);
      } else {
        throw Exception("Firebase update failed");
      }
    } catch (e) {
      print("⚠️ Firebase sync failed for field '$field' (attempt ${retryCount + 1}): $e");
      
      if (retryCount < _maxRetries) {

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

  Future<void> _ensurePresetExistsInFirebase(Preset preset) async {
    try {
      await _addPresetToFirebase(preset);
    } catch (e) {

      print("Preset might already exist in Firebase: $e");
    }
  }

  Future<bool> _updatePresetFieldInFirebase(Preset preset, String field, String value) async {
    try {
      final user = _authService.currentUser;
      if (user == null) return false;

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

      await docRef.update({
        field: value,
        'lastModified': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });

      return true;
    } catch (e) {
      print("❌ Error updating preset field in Firebase: $e");
      return false;
    }
  }


  Future<void> _startRealtimeListeners() async {
    final user = _authService.currentUser;
    if (user == null) {
      print("⚠️ Cannot start listeners - no user signed in");
      return;
    }
    
    // Stop any existing listeners first
    if (_isListening) {
      print("🔄 Stopping existing listeners before starting new ones");
      await stopRealtimeListeners();
    }

    // Wait a bit to ensure Firebase Auth token is propagated to Firestore
    // This helps prevent permission-denied errors immediately after sign-in
    await Future.delayed(const Duration(milliseconds: 500));

    print("🔄 Starting real-time Firebase listeners for user ${user.uid}...");
    _isListening = true;

    try {
      // Verify user hasn't changed during the delay
      final currentUser = _authService.currentUser;
      if (currentUser == null || currentUser.uid != user.uid) {
        print("⚠️ User changed or signed out during listener setup - aborting");
        _isListening = false;
        return;
      }

      // Check if user document exists before setting up listener
      // This prevents errors when accessing subcollections for new users
      try {
        final userDocRef = _firestore.collection('users').doc(user.uid);
        final userDocSnapshot = await userDocRef.get();
        
        if (!userDocSnapshot.exists) {
          print("📁 User document doesn't exist yet - setting up listener anyway (will work once document is created)");
        }
      } catch (e) {
        print("⚠️ Could not check user document existence: $e");
        // Continue anyway - listener will handle errors
      }

      _collectionsListener = _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .snapshots()
          .listen(
            _onCollectionsChanged,
            onError: (error) {
              print("❌ Collections listener error: $error");
              final errorString = error.toString().toLowerCase();
              if (errorString.contains('permission-denied') || 
                  errorString.contains('missing or insufficient permissions')) {
                print("⚠️ Permission denied - user may not be fully authenticated yet");
                // Don't set _isListening to false - we'll retry later
                // The listener will be restarted when user data loads successfully
              } else if (errorString.contains('internal') || 
                         errorString.contains('server error')) {
                print("⚠️ Internal server error in collections listener - user document may not exist yet");
                // This is okay for new users - the listener will work once data exists
              }
            },
          );

      await _startPresetsListeners();

      print("✅ Real-time Firebase listeners started successfully");
    } catch (e) {
      print("❌ Error starting real-time listeners: $e");
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("⚠️ Permission denied - will retry after authentication is ready");
        // Don't mark as listening so we can retry
        _isListening = false;
      } else {
        _isListening = false;
      }
    }
  }

  Future<void> _startPresetsListeners() async {
    final user = _authService.currentUser;
    if (user == null) return;

    await _presetsListener?.cancel();

    _isInitialListenerFire = true;

    _startLivePresetsListener();
  }

  Future<void> _startLivePresetsListener() async {
    final user = _authService.currentUser;
    if (user == null) return;

    _presetsListener = _firestore
        .collection('users')
        .doc(user.uid)
        .collection('collections')
        .snapshots()
        .listen(
          (collectionsSnapshot) async {
            // Verify user hasn't changed
            final currentUser = _authService.currentUser;
            if (currentUser == null || currentUser.uid != user.uid) {
              print("⚠️ User changed during presets listener callback - ignoring");
              return;
            }

            try {
              // If no collections exist, that's fine - user just hasn't created any yet
              if (collectionsSnapshot.docs.isEmpty) {
                print("📁 No collections in listener snapshot - clearing presets");
                _localPresets.clear();
                _localPostDeliveryPresets.clear();
                _saveLocalCache();
                _notifyDataChanged();
                return;
              }

              final List<Preset> allPresets = [];
              
              for (final collectionDoc in collectionsSnapshot.docs) {
                final collectionId = collectionDoc.id;
                final collectionData = collectionDoc.data();
                final collectionName = (collectionData is Map<String, dynamic>)
                    ? (collectionData['name'] ?? 'Default')
                    : 'Default';

                _collectionNameToId[collectionName] = collectionId;

                try {
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
                } catch (e) {
                  final errorString = e.toString().toLowerCase();
                  if (errorString.contains('permission-denied') || 
                      errorString.contains('missing or insufficient permissions')) {
                    print("⚠️ Permission denied reading presets for collection $collectionId - user may not have access");
                  } else if (errorString.contains('internal') || 
                             errorString.contains('server error')) {
                    print("⚠️ Internal server error reading presets for collection $collectionId - collection may not exist yet");
                  } else {
                    print("❌ Error reading presets for collection $collectionId: $e");
                  }
                }
              }

              _mergePresetsFromFirebase(allPresets);
              _saveLocalCache();
              _notifyDataChanged();
            } catch (e) {
              final errorString = e.toString().toLowerCase();
              if (errorString.contains('permission-denied') || 
                  errorString.contains('missing or insufficient permissions')) {
                print("⚠️ Permission denied in presets listener - user may not be fully authenticated");
              } else if (errorString.contains('internal') || 
                         errorString.contains('server error')) {
                print("⚠️ Internal server error in presets listener - user document may not exist yet");
                // Clear presets for new users
                _localPresets.clear();
                _localPostDeliveryPresets.clear();
                _saveLocalCache();
                _notifyDataChanged();
              } else {
                print("❌ Error in presets listener callback: $e");
              }
            }
          },
          onError: (error) {
            print("❌ Presets listener error: $error");
            final errorString = error.toString().toLowerCase();
            if (errorString.contains('permission-denied') || 
                errorString.contains('missing or insufficient permissions')) {
              print("⚠️ Permission denied - user may not be fully authenticated yet");
            } else if (errorString.contains('internal') || 
                       errorString.contains('server error')) {
              print("⚠️ Internal server error - user document may not exist yet (normal for new users)");
            }
          },
        );
  }

  String _getPresetTypeFromPreset(Preset preset) {

    if (preset.postProcessingUrl.toLowerCase().contains('post-delivery')) {
      return 'post-delivery';
    } else if (preset.postProcessingUrl.toLowerCase().contains('nano-banana')) {
      return 'nano-banana';
    }

    return 'nano-banana';
  }

  void _mergePresetsFromFirebase(List<Preset> firebasePresets) {

    if (_editingPresets.isNotEmpty) {
      print("🔄 Skipping merge - presets are being edited: $_editingPresets");
      return;
    }

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

    final mergedPresets = <Preset>[];

    final allPresetIds = <String>{};
    allPresetIds.addAll(localPresetsMap.keys);
    allPresetIds.addAll(firebasePresetsMap.keys);
    
    for (final presetId in allPresetIds) {
      final localPreset = localPresetsMap[presetId];
      final firebasePreset = firebasePresetsMap[presetId];
      
      if (localPreset != null && firebasePreset != null) {

        if (localPreset.isLocalChange && localPreset.lastModified > firebasePreset.lastModified) {

          mergedPresets.add(localPreset);
          print("🔄 Conflict resolved: keeping local version of preset '$presetId'");
        } else {

          mergedPresets.add(firebasePreset);
        }
      } else if (localPreset != null) {

        mergedPresets.add(localPreset);
      } else if (firebasePreset != null) {

        mergedPresets.add(firebasePreset);
      }
    }

    _localPresets.clear();
    _localPostDeliveryPresets.clear();
    
    for (final preset in mergedPresets) {

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

  void _mergePostDeliveryPresetsFromFirebase(List<Preset> firebasePresets) {

    if (_editingPresets.isNotEmpty) {
      print("🔄 Skipping post-delivery merge - presets are being edited: $_editingPresets");
      return;
    }

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

    final mergedPresets = <Preset>[];

    final allPresetIds = <String>{};
    allPresetIds.addAll(localPresetsMap.keys);
    allPresetIds.addAll(firebasePresetsMap.keys);
    
    for (final presetId in allPresetIds) {
      final localPreset = localPresetsMap[presetId];
      final firebasePreset = firebasePresetsMap[presetId];
      
      if (localPreset != null && firebasePreset != null) {

        if (localPreset.isLocalChange && localPreset.lastModified > firebasePreset.lastModified) {

          mergedPresets.add(localPreset);
          print("🔄 Post-delivery conflict resolved: keeping local version of preset '$presetId'");
        } else {

          mergedPresets.add(firebasePreset);
        }
      } else if (localPreset != null) {

        mergedPresets.add(localPreset);
      } else if (firebasePreset != null) {

        mergedPresets.add(firebasePreset);
      }
    }
    
    _localPostDeliveryPresets = mergedPresets;
    print("🔄 Merged post-delivery presets with conflict resolution: ${mergedPresets.length} total");
  }

  void _mergeLocalChangesWithFirebaseData(List<Preset> currentLocalPresets, List<Collection> currentLocalCollections) {

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

    final mergedPresets = <Preset>[];
    final mergedCollections = <Collection>[];

    mergedPresets.addAll(_localPresets);

    for (final localPreset in currentLocalPresets) {
      if (localPreset.presetId.isNotEmpty && !firebasePresetsMap.containsKey(localPreset.presetId)) {

        mergedPresets.add(localPreset);
      }
    }

    mergedCollections.addAll(_localCollections);

    for (final localCollection in currentLocalCollections) {
      if (localCollection.name.isNotEmpty && !firebaseCollectionsMap.containsKey(localCollection.name)) {
        mergedCollections.add(localCollection);
      }
    }
    
    _localPresets = mergedPresets;
    _localCollections = mergedCollections;
    
    print("🔄 Merged local changes with Firebase data: ${mergedPresets.length} presets, ${mergedCollections.length} collections");
  }

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

      if (_dataSource == 'live') {
        _localCollections = newCollections;
      } else {
        _localPostDeliveryCollections = newCollections;
      }

      _saveLocalCache();

      _notifyDataChanged();

      print("✅ Collections updated from real-time listener: ${newCollections.length} items");
    } catch (e) {
      print("❌ Error processing collections change: $e");
    }
  }

  void _onPresetsChanged(List<Preset> allPresets) {
    print("📡 Presets changed - processing ${allPresets.length} presets");

    if (_isInitialListenerFire) {
      print("🔄 Skipping initial listener fire - data already loaded during initialization");
      _isInitialListenerFire = false;
      return;
    }
    
    try {

      final livePresets = <Preset>[];
      final postDeliveryPresets = <Preset>[];
      
      for (final preset in allPresets) {



        _loadUserDataFromFirebase();
        return;
      }

      _saveLocalCache();

      _notifyDataChanged();

      print("✅ Presets updated from real-time listener: ${allPresets.length} items");
    } catch (e) {
      print("❌ Error processing presets change: $e");
    }
  }

  Future<void> stopRealtimeListeners() async {
    print("🛑 Stopping real-time Firebase listeners...");
    
    await _collectionsListener?.cancel();
    await _presetsListener?.cancel();
    
    _collectionsListener = null;
    _presetsListener = null;
    _isListening = false;
    
    print("✅ Real-time Firebase listeners stopped");
  }

  bool get isListening => _isListening;

  Future<void> restartListeners() async {
    await stopRealtimeListeners();
    await _startRealtimeListeners();
  }

  void setDataChangedCallback(VoidCallback callback) {
    _onDataChanged = callback;
  }

  void _notifyDataChanged() {
    _onDataChanged?.call();
  }

  void updateDataSource(String dataSource) {
    _dataSource = dataSource;
    if (_isListening) {
      restartListeners();
    }
  }

  /// Reset user state when user signs out
  /// This ensures a fresh sync when a new user signs in
  Future<void> resetUserState() async {
    print("🔄 PresetService: Resetting user state");
    // Stop listeners when user signs out
    stopRealtimeListeners();
    _currentUserId = null;
    _initialSyncCompleted = false;
    _lastFirebaseSync = null;
    _localPresets.clear();
    _localCollections.clear();
    _localPostDeliveryPresets.clear();
    _localPostDeliveryCollections.clear();
    _presetsLoadedFromFirebase = false;
    _collectionsLoadedFromFirebase = false;
    _postDeliveryPresetsLoadedFromFirebase = false;
    _postDeliveryCollectionsLoadedFromFirebase = false;
    _isInitialListenerFire = true;
    // Clear SharedPreferences cache on sign-out only (not on app restart)
    await _clearLocalCache();
  }
}
