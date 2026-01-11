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

  final Map<String, StreamSubscription<QuerySnapshot>> _presetSubListeners = {};
  final Map<String, List<Preset>> _livePresetsByCollectionId = {};
  final Map<String, String> _collectionIdToName = {};
  List<String> _collectionOrder = const [];

  String _lastAppliedPresetsSignature = '';

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
    
    final user = _authService.currentUser;
    if (user == null) {
      _currentUserId = null;
      _localPresets.clear();
      _localCollections.clear();
      _localPostDeliveryPresets.clear();
      _localPostDeliveryCollections.clear();
      return;
    }
    
    final userChanged = _currentUserId != null && _currentUserId != user.uid;
    if (userChanged) {
      assert(() {
        print("ðŸ”„ User changed from '$_currentUserId' to '${user.uid}', clearing old data");
        return true;
      }());
      await stopRealtimeListeners();
      _initialSyncCompleted = false;
      _lastFirebaseSync = null;
      _currentUserId = user.uid;
      _localPresets.clear();
      _localCollections.clear();
      _localPostDeliveryPresets.clear();
      _localPostDeliveryCollections.clear();
    } else if (_currentUserId == null) {
      _currentUserId = user.uid;
    }
    
    if (!userChanged) {
      await _loadFromLocalCache();
      assert(() {
        print("ðŸ“ Loaded data from local cache");
        return true;
      }());
    } else {
      assert(() {
        print("ðŸ“ Skipping cache load - user changed, will fetch fresh data");
        return true;
      }());
    }
    
    await _loadUserDataFromFirebase();
    
    await _startRealtimeListeners();
    
    if (!_isListening) {
      assert(() {
        print("â³ Waiting before retrying listener setup...");
        return true;
      }());
      await Future.delayed(const Duration(seconds: 2));
      final retryUser = _authService.currentUser;
      if (retryUser != null && retryUser.uid == user.uid) {
        assert(() {
          print("ðŸ”„ Retrying listener setup...");
          return true;
        }());
        await _startRealtimeListeners();
      }
    }
  }

  Future<void> _loadUserDataFromFirebase() async {
    final user = _authService.currentUser;
    if (user == null) return;

    final currentTime = DateTime.now();
    
    if (_currentUserId != null && _currentUserId != user.uid) {
      print("âš ï¸ User mismatch detected in _loadUserDataFromFirebase - aborting");
      return;
    }
    
    if (_currentUserId == null) {
      _currentUserId = user.uid;
    }

    final needsSync = !_initialSyncCompleted || 
                     _lastFirebaseSync == null ||
                     currentTime.difference(_lastFirebaseSync!) > _firebaseSyncInterval;

    if (needsSync) {
      assert(() {
        print("ðŸ”„ Performing Firebase sync...");
        return true;
      }());
      await _performFirebaseSync();
      _initialSyncCompleted = true;
      _lastFirebaseSync = currentTime;
      await LogService.log('PresetService: Firebase sync complete');
      _notifyDataChanged();
    } else {
      assert(() {
        print("ðŸš€ Using cached data, Firebase sync not needed");
        return true;
      }());
      _notifyDataChanged();
    }
  }

  Future<void> _performFirebaseSync() async {
    try {
      await _fetchUserPresets();
      await _fetchUserCollections();
      
      await _saveLocalCache();
      await LogService.log(
        "Firebase sync completed successfully (livePresets=${_localPresets.length}, postPresets=${_localPostDeliveryPresets.length}, collections=${_localCollections.length})",
      );
      assert(() {
        print("âœ… Firebase sync completed successfully");
        return true;
      }());
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("âš ï¸ Permission denied during sync - user may not be fully authenticated yet: $e");
      } else if (errorString.contains('internal') || 
                 errorString.contains('server error')) {
        print("âš ï¸ Internal server error during sync - user document may not exist yet (normal for new users): $e");
      } else {
        print("âŒ Firebase sync failed: $e, using local cache");
      }
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
      assert(() {
        print("âœ… Loaded ${_localPresets.length} live presets and ${_localPostDeliveryPresets.length} post-delivery presets");
        return true;
      }());
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("âš ï¸ Permission denied fetching presets - user may not be fully authenticated yet: $e");
      } else {
        print("âŒ Error fetching presets: $e");
      }
    }
  }

  Future<void> _fetchAllPresetsFromCollections(String userId) async {
    try {
      final userDocRef = _firestore.collection('users').doc(userId);
      final userDocSnapshot = await userDocRef.get();
      
      if (!userDocSnapshot.exists) {
        print("ðŸ“ User document doesn't exist yet - this is normal for new users");
        _localPresets.clear();
        _localPostDeliveryPresets.clear();
        return;
      }
      
      final collectionsSnapshot = await userDocRef.collection('collections').get();
      
      if (collectionsSnapshot.docs.isEmpty) {
        print("ðŸ“ No collections found for user - this is normal for new users");
        _localPresets.clear();
        _localPostDeliveryPresets.clear();
        return;
      }

      for (final collectionDoc in collectionsSnapshot.docs) {
        final collectionData = collectionDoc.data();
        final collectionName = collectionData['name'] ?? 'Default';
        final collectionId = collectionDoc.id;
        
        assert(() {
          print("ðŸ” Fetching presets from collection: $collectionName");
          return true;
        }());

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
          assert(() {
            print("ðŸ“„ Preset '${preset.title}' has presetType: $presetType");
            return true;
          }());
          
          if (presetType == 'post-delivery') {
            _localPostDeliveryPresets.add(preset);
            assert(() {
              print("âœ… Added to POST-DELIVERY presets");
              return true;
            }());
          } else {
            _localPresets.add(preset);
            assert(() {
              print("âœ… Added to LIVE presets");
              return true;
            }());
          }
        }
      }
      
      assert(() {
        print("âœ… Fetched ${_localPresets.length} LIVE presets and ${_localPostDeliveryPresets.length} POST-DELIVERY presets from collections");
        return true;
      }());
    } catch (e) {
      print("âŒ Error fetching presets from collections: $e");
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
      assert(() {
        print("âœ… Loaded ${_localCollections.length} live collections and ${_localPostDeliveryCollections.length} post-delivery collections");
        return true;
      }());
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("âš ï¸ Permission denied fetching collections - user may not be fully authenticated yet: $e");
      } else {
        print("âŒ Error fetching collections: $e");
      }
    }
  }

  Future<void> _fetchAllCollections(String userId) async {
    try {
      final userDocRef = _firestore.collection('users').doc(userId);
      final userDocSnapshot = await userDocRef.get();
      
      if (!userDocSnapshot.exists) {
        print("ðŸ“ User document doesn't exist yet - this is normal for new users");
        _localCollections.clear();
        _localPostDeliveryCollections.clear();
        return;
      }
      
      final collectionsSnapshot = await userDocRef.collection('collections').get();
      
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
      
      assert(() {
        print("âœ… Fetched ${_localCollections.length} collections from Firebase");
        return true;
      }());
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("âš ï¸ Permission denied fetching collections - user may not be fully authenticated yet: $e");
        _localCollections.clear();
        _localPostDeliveryCollections.clear();
      } else {
        print("âŒ Error fetching collections: $e");
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
      print("âŒ Error categorizing collections: $e");
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

      print("âœ… Created collection '$collectionName' with ID '$collectionId' in Firebase");
    } catch (e) {
      print("âŒ Error creating collection in Firebase: $e");
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
        
    print("âœ… Preset '${preset.title.isNotEmpty ? preset.title : preset.name}' (type: $presetType) saved to Firebase collections/$collectionId/presets/${preset.presetId}");
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
      _lastAppliedPresetsSignature = _presetSignature([
        ..._localPresets,
        ..._localPostDeliveryPresets,
      ]);
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
      final decoded = jsonDecode(presetsString);
      if (decoded is List) {
        _localPresets = decoded
            .whereType<Map>()
            .map((m) => Preset.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    }

    final collectionsString = prefs.getString('local_collections');
    if (collectionsString != null) {
      final decoded = jsonDecode(collectionsString);
      if (decoded is List) {
        _localCollections = decoded
            .whereType<Map>()
            .map((m) => Collection.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    }

    final postDeliveryPresetsString = prefs.getString('local_post_delivery_presets');
    if (postDeliveryPresetsString != null) {
      final decoded = jsonDecode(postDeliveryPresetsString);
      if (decoded is List) {
        _localPostDeliveryPresets = decoded
            .whereType<Map>()
            .map((m) => Preset.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    }

    final postDeliveryCollectionsString = prefs.getString('local_post_delivery_collections');
    if (postDeliveryCollectionsString != null) {
      final decoded = jsonDecode(postDeliveryCollectionsString);
      if (decoded is List) {
        _localPostDeliveryCollections = decoded
            .whereType<Map>()
            .map((m) => Collection.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    }
  }

  Future<void> _clearLocalCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('local_presets');
      await prefs.remove('local_collections');
      await prefs.remove('local_post_delivery_presets');
      await prefs.remove('local_post_delivery_collections');
      print('âœ… Cleared SharedPreferences cache');
    } catch (e) {
      print('âŒ Failed to clear SharedPreferences cache: $e');
    }
  }

  List<Preset> getPresetsForDataSource(String dataSource) {

    final isLive = dataSource == 'live';
    final presets = isLive ? _localPresets : _localPostDeliveryPresets;
    assert(() {
      print("ðŸ” getPresetsForDataSource('$dataSource'): returning ${presets.length} presets");
      print("   Live presets: ${_localPresets.length}, Post-delivery presets: ${_localPostDeliveryPresets.length}");
      for (final preset in presets) {
        print("  - ${preset.title} (ID: ${preset.presetId}, collection: '${preset.collection}')");
      }
      return true;
    }());
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
    assert(() {
      print("ðŸ” getCollectionsForDataSource('$dataSource'): returning ${result.length} collections");
      for (final collection in result) {
        print("   - '${collection.name}' (ID: ${collection.id})");
      }
      return true;
    }());
    return result;
  }



  Future<void> _startRealtimeListeners() async {
    final user = _authService.currentUser;
    if (user == null) {
      print("âš ï¸ Cannot start listeners - no user signed in");
      return;
    }
    
    if (_isListening) {
      assert(() {
        print("ðŸ”„ Stopping existing listeners before starting new ones");
        return true;
      }());
      await stopRealtimeListeners();
    }

    await Future.delayed(const Duration(milliseconds: 500));

    assert(() {
      print("ðŸ”„ Starting real-time Firebase listeners for user ${user.uid}...");
      return true;
    }());
    _isListening = true;

    try {
      final currentUser = _authService.currentUser;
      if (currentUser == null || currentUser.uid != user.uid) {
        print("âš ï¸ User changed or signed out during listener setup - aborting");
        _isListening = false;
        return;
      }

      try {
        final userDocRef = _firestore.collection('users').doc(user.uid);
        final userDocSnapshot = await userDocRef.get();
        
        if (!userDocSnapshot.exists) {
          print("ðŸ“ User document doesn't exist yet - setting up listener anyway (will work once document is created)");
        }
      } catch (e) {
        print("âš ï¸ Could not check user document existence: $e");
      }

      _collectionsListener = _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .snapshots()
          .listen(
            _onCollectionsChanged,
            onError: (error) {
              print("âŒ Collections listener error: $error");
              final errorString = error.toString().toLowerCase();
              if (errorString.contains('permission-denied') || 
                  errorString.contains('missing or insufficient permissions')) {
                print("âš ï¸ Permission denied - user may not be fully authenticated yet");
              } else if (errorString.contains('internal') || 
                         errorString.contains('server error')) {
                print("âš ï¸ Internal server error in collections listener - user document may not exist yet");
              }
            },
          );

      await _startPresetsListeners();

      print("âœ… Real-time Firebase listeners started successfully");
    } catch (e) {
      print("âŒ Error starting real-time listeners: $e");
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        print("âš ï¸ Permission denied - will retry after authentication is ready");
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

    for (final sub in _presetSubListeners.values) {
      await sub.cancel();
    }
    _presetSubListeners.clear();
    _livePresetsByCollectionId.clear();
    _collectionIdToName.clear();
    _collectionOrder = const [];

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
            final currentUser = _authService.currentUser;
            if (currentUser == null || currentUser.uid != user.uid) {
              print("âš ï¸ User changed during presets listener callback - ignoring");
              return;
            }

            try {
              if (collectionsSnapshot.docs.isEmpty) {
                print("ðŸ“ No collections in listener snapshot - clearing presets");
                _localPresets.clear();
                _localPostDeliveryPresets.clear();
                for (final sub in _presetSubListeners.values) {
                  await sub.cancel();
                }
                _presetSubListeners.clear();
                _livePresetsByCollectionId.clear();
                _collectionIdToName.clear();
                _collectionOrder = const [];
                _saveLocalCache();
                _notifyDataChanged();
                return;
              }

              _collectionOrder = collectionsSnapshot.docs.map((d) => d.id).toList(growable: false);

              final currentIds = collectionsSnapshot.docs.map((d) => d.id).toSet();

              for (final existingId in _presetSubListeners.keys.toList()) {
                if (!currentIds.contains(existingId)) {
                  await _presetSubListeners[existingId]?.cancel();
                  _presetSubListeners.remove(existingId);
                  _livePresetsByCollectionId.remove(existingId);
                  _collectionIdToName.remove(existingId);
                }
              }

              for (final collectionDoc in collectionsSnapshot.docs) {
                final collectionId = collectionDoc.id;
                final collectionData = collectionDoc.data();
                final collectionName = (collectionData is Map<String, dynamic>)
                    ? (collectionData['name'] ?? 'Default')
                    : 'Default';

                _collectionNameToId[collectionName] = collectionId;
                _collectionIdToName[collectionId] = collectionName;

                final existingPresets = _livePresetsByCollectionId[collectionId];
                if (existingPresets != null && existingPresets.isNotEmpty) {
                  final updated = existingPresets
                      .map((p) => p.collection == collectionName ? p : p.copyWith(collection: collectionName))
                      .toList(growable: false);
                  _livePresetsByCollectionId[collectionId] = updated;
                }

                _presetSubListeners[collectionId] ??= _firestore
                      .collection('users')
                      .doc(user.uid)
                      .collection('collections')
                      .doc(collectionId)
                      .collection('presets')
                    .snapshots()
                    .listen(
                  (presetsSnapshot) async {
                    try {
                      final currentUser2 = _authService.currentUser;
                      if (currentUser2 == null || currentUser2.uid != user.uid) {
                        return;
                      }

                      final name = _collectionIdToName[collectionId] ?? 'Default';
                      final presets = <Preset>[];
                  
                      for (final presetDoc in presetsSnapshot.docs) {
                        final raw = presetDoc.data();
                        if (raw is! Map) continue;
                        final data = raw.cast<String, dynamic>();
                        presets.add(Preset.fromMap({
                          ...data,
                          'presetId': presetDoc.id,
                          'collectionId': collectionId,
                          'collection': name,
                          'prompt': (data['prompt'] ?? ''),
                          'thumbnailPath': data['thumbnailPath'] ?? data['generatedImageUrls'],
                        }));
                      }

                      _livePresetsByCollectionId[collectionId] = presets;

                      final allPresets = <Preset>[];
                      for (final cid in _collectionOrder) {
                        final list = _livePresetsByCollectionId[cid];
                        if (list != null && list.isNotEmpty) {
                          allPresets.addAll(list);
                  }
                }

                      final changed = _applyFirebasePresets(allPresets);
                      if (changed) {
                        await _saveLocalCache();
              _notifyDataChanged();
                      }
                    } catch (e) {
                      print("âŒ Error processing presets sub-listener for collection $collectionId: $e");
                    }
                  },
                  onError: (error) {
                    print("âŒ Presets sub-listener error for collection $collectionId: $error");
                  },
                );
              }
            } catch (e) {
              final errorString = e.toString().toLowerCase();
              if (errorString.contains('permission-denied') || 
                  errorString.contains('missing or insufficient permissions')) {
                print("âš ï¸ Permission denied in presets listener - user may not be fully authenticated");
              } else if (errorString.contains('internal') || 
                         errorString.contains('server error')) {
                print("âš ï¸ Internal server error in presets listener - user document may not exist yet");
                _localPresets.clear();
                _localPostDeliveryPresets.clear();
                _saveLocalCache();
                _notifyDataChanged();
              } else {
                print("âŒ Error in presets listener callback: $e");
              }
            }
          },
          onError: (error) {
            print("âŒ Presets listener error: $error");
            final errorString = error.toString().toLowerCase();
            if (errorString.contains('permission-denied') || 
                errorString.contains('missing or insufficient permissions')) {
              print("âš ï¸ Permission denied - user may not be fully authenticated yet");
            } else if (errorString.contains('internal') || 
                       errorString.contains('server error')) {
              print("âš ï¸ Internal server error - user document may not exist yet (normal for new users)");
            }
          },
        );
  }

  bool _applyFirebasePresets(List<Preset> firebasePresets) {
    final sig = _presetSignature(firebasePresets);
    if (sig == _lastAppliedPresetsSignature) {
      return false;
    }
    _lastAppliedPresetsSignature = sig;

    final live = <Preset>[];
    final post = <Preset>[];

    for (final preset in firebasePresets) {
      final presetType = _getPresetTypeFromPreset(preset);
      if (presetType == 'post-delivery') {
        post.add(preset);
      } else {
        live.add(preset);
      }
    }

    _localPresets = live;
    _localPostDeliveryPresets = post;
    return true;
  }

  String _presetSignature(List<Preset> presets) {
    final rows = presets
        .where((p) => p.presetId.isNotEmpty)
        .map((p) => '${p.presetId}|${p.collectionId}|${p.title}|${p.postProcessingUrl}|${p.generatedImageUrls}|${p.thumbnailPath}|${p.collection}|${p.prompt}')
        .toList();
    rows.sort();
    return rows.join('||');
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
      assert(() {
        print("ðŸ”„ Skipping merge - presets are being edited: $_editingPresets");
        return true;
      }());
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
          assert(() {
            print("ðŸ”„ Conflict resolved: keeping local version of preset '$presetId'");
            return true;
          }());
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
    
    assert(() {
      print("ðŸ”„ Merged presets with conflict resolution: ${mergedPresets.length} total");
      return true;
    }());
    print("   Re-categorized: ${_localPresets.length} live, ${_localPostDeliveryPresets.length} post-delivery");
  }

  void _mergePostDeliveryPresetsFromFirebase(List<Preset> firebasePresets) {

    if (_editingPresets.isNotEmpty) {
      assert(() {
        print("ðŸ”„ Skipping post-delivery merge - presets are being edited: $_editingPresets");
        return true;
      }());
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
          assert(() {
            print("ðŸ”„ Post-delivery conflict resolved: keeping local version of preset '$presetId'");
            return true;
          }());
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
    assert(() {
      print("ðŸ”„ Merged post-delivery presets with conflict resolution: ${mergedPresets.length} total");
      return true;
    }());
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
    
    assert(() {
      print("ðŸ”„ Merged local changes with Firebase data: ${mergedPresets.length} presets, ${mergedCollections.length} collections");
      return true;
    }());
  }

  void _onCollectionsChanged(QuerySnapshot snapshot) {
    assert(() {
      print("ðŸ“¡ Collections changed - processing ${snapshot.docs.length} collections");
      return true;
    }());
    
    try {
      final newCollections = <Collection>[];
      
      for (final doc in snapshot.docs) {
        final raw = doc.data();
        if (raw is! Map) continue;
        final data = raw.cast<String, dynamic>();
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

      assert(() {
        print("âœ… Collections updated from real-time listener: ${newCollections.length} items");
        return true;
      }());
    } catch (e) {
      print("âŒ Error processing collections change: $e");
    }
  }

  void _onPresetsChanged(List<Preset> allPresets) {
    assert(() {
      print("ðŸ“¡ Presets changed - processing ${allPresets.length} presets");
      return true;
    }());

    if (_isInitialListenerFire) {
      assert(() {
        print("ðŸ”„ Skipping initial listener fire - data already loaded during initialization");
        return true;
      }());
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

      assert(() {
        print("âœ… Presets updated from real-time listener: ${allPresets.length} items");
        return true;
      }());
    } catch (e) {
      print("âŒ Error processing presets change: $e");
    }
  }

  Future<void> stopRealtimeListeners() async {
    assert(() {
      print("ðŸ›‘ Stopping real-time Firebase listeners...");
      return true;
    }());
    
    await _collectionsListener?.cancel();
    await _presetsListener?.cancel();

    for (final sub in _presetSubListeners.values) {
      await sub.cancel();
    }
    _presetSubListeners.clear();
    _livePresetsByCollectionId.clear();
    _collectionIdToName.clear();
    _collectionOrder = const [];
    
    _collectionsListener = null;
    _presetsListener = null;
    _isListening = false;
    
    print("âœ… Real-time Firebase listeners stopped");
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

  Future<void> resetUserState() async {
    assert(() {
      print("ðŸ”„ PresetService: Resetting user state");
      return true;
    }());
    stopRealtimeListeners();
    
    for (final timer in _debounceTimers.values) {
      timer.cancel();
    }
    _debounceTimers.clear();
    
    _currentUserId = null;
    _initialSyncCompleted = false;
    _lastFirebaseSync = null;
    _localPresets.clear();
    _localCollections.clear();
    _localPostDeliveryPresets.clear();
    _localPostDeliveryCollections.clear();
    _presetSubListeners.clear();
    _livePresetsByCollectionId.clear();
    _collectionIdToName.clear();
    _collectionOrder = const [];
    _lastAppliedPresetsSignature = '';
    _presetsLoadedFromFirebase = false;
    _collectionsLoadedFromFirebase = false;
    _postDeliveryPresetsLoadedFromFirebase = false;
    _postDeliveryCollectionsLoadedFromFirebase = false;
    _isInitialListenerFire = true;
    
    _editingPresets.clear();
    _retryCounts.clear();
    
    await _clearLocalCache();
  }
}
