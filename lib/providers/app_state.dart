import 'package:flutter/material.dart';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user.dart' as app_user;
import '../models/preset.dart';
import '../models/collection.dart';
import '../services/auth_service.dart';
import '../services/preset_service.dart';

class AppState extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final PresetService _presetService = PresetService();
  
  app_user.User? _currentUser;
  List<Preset> _presets = [];
  List<Collection> _collections = [];
  bool _isDarkMode = false;
  bool _noEffectsEnabled = false;
  String _dataSource = "live";
  bool _isLoading = false;
  int _selectedIndex = 0;
  bool _stayMinimizedDuringCapture = false;
  String _presetPassword = '';

  app_user.User? get currentUser => _currentUser;
  List<Preset> get presets => _presets;
  List<Collection> get collections => _collections;
  bool get isDarkMode => _isDarkMode;
  bool get noEffectsEnabled => _noEffectsEnabled;
  String get dataSource => _dataSource;
  bool get isLoading => _isLoading;
  int get selectedIndex => _selectedIndex;
  bool get stayMinimizedDuringCapture => _stayMinimizedDuringCapture;
  String get presetPassword => _presetPassword;

  void initialize() {
    print('AppState:initialize');
    _presetService.setDataChangedCallback(handleRealtimeUpdate);
    
    _authService.userStream.listen((user) {
      _currentUser = user;
      if (user != null) {
        print('AppState:user signed in ${user.uid}');
        _loadUserData();
        _loadUserSettings();
      } else {
        print('AppState:user signed out');
        _presets.clear();
        _collections.clear();
        _presetPassword = '';
      }
      notifyListeners();
    });
  }

  Future<void> _loadUserData() async {
    if (_currentUser == null) return;
    
    _setLoading(true);
    try {
      await _presetService.initialize();
      _presets = _presetService.getPresetsForDataSource(_dataSource);
      _collections = _presetService.getCollectionsForDataSource(_dataSource);
    } catch (e) {
      debugPrint('Error loading user data: $e');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _loadUserSettings() async {
    try {
      if (_currentUser == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .get();
      final data = doc.data();
      if (data != null) {
        _presetPassword = (data['presetPassword'] ?? '') as String;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error loading user settings: $e');
    }
  }

  void toggleDarkMode() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }

  void toggleNoEffects() {
    _noEffectsEnabled = !_noEffectsEnabled;
    notifyListeners();
  }

  void setSelectedIndex(int index) {
    if (index >= 0 && index < _presets.length) {
      _selectedIndex = index;
      notifyListeners();
    }
  }

  void setStayMinimizedDuringCapture(bool value) {
    _stayMinimizedDuringCapture = value;
    notifyListeners();
  }

  Preset createNoEffectsPreset() {
    return Preset(
      title: "No Effects",
      name: "No Effects",
      presetId: "no_effects_virtual",
      collectionId: "virtual",
      isNoEffects: true,
    );
  }

  void setDataSource(String source) {
    print("🔄 AppState: Switching data source from '$_dataSource' to '$source'");
    _dataSource = source;
    
    _presetService.recategorizePresets();
    
    _presets = _presetService.getPresetsForDataSource(_dataSource);
    _collections = _presetService.getCollectionsForDataSource(_dataSource);
    
    print("🔄 AppState: After switch - ${_presets.length} presets, ${_collections.length} collections");
    
    _presetService.updateDataSource(_dataSource);
    
    notifyListeners();
  }

  Future<void> addCollection(Collection collection) async {
    try {
      final collectionId = _generateRandomId(8);
      
      await _presetService.createCollectionInFirebase(collection.name, collectionId);
      
      _collections.add(collection);
      
      await _presetService.initialize();
      _collections = _presetService.getCollectionsForDataSource(_dataSource);
      
      notifyListeners();
    } catch (e) {
      debugPrint('Error adding collection: $e');
    }
  }

  String _generateRandomId(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(
      Iterable.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  Future<void> updateCollection(Collection collection) async {
    try {
      await _authService.saveCollection(collection);
      final index = _collections.indexWhere((c) => c.name == collection.name);
      if (index != -1) {
        _collections[index] = collection;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error updating collection: $e');
    }
  }

  Future<void> deleteCollection(String collectionName) async {
    try {
      await _authService.deleteCollection(collectionName);
      _collections.removeWhere((c) => c.name == collectionName);
      notifyListeners();
    } catch (e) {
      debugPrint('Error deleting collection: $e');
    }
  }

  Future<void> signInWithEmailAndPassword(String email, String password) async {
    try {
      await _authService.signInWithEmailAndPassword(email, password);
    } catch (e) {
      debugPrint('Error signing in: $e');
      rethrow;
    }
  }

  Future<void> signInWithGoogle() async {
    try {
      await _authService.signInWithGoogle();
    } catch (e) {
      debugPrint('Error signing in with Google: $e');
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      await _authService.signOut();
      _currentUser = null;
      _presets.clear();
      _collections.clear();
      notifyListeners();
    } catch (e) {
      debugPrint('Error signing out: $e');
    }
  }

  void navigateToSavedPresets() {
    debugPrint('Navigate to saved presets');
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void handleRealtimeUpdate() {
    print("🔄 AppState: Handling real-time update from Firebase");
    
    _presets = _presetService.getPresetsForDataSource(_dataSource);
    _collections = _presetService.getCollectionsForDataSource(_dataSource);
    
    notifyListeners();
    
    print("✅ AppState: Updated with ${_presets.length} presets and ${_collections.length} collections");
  }

  bool get isRealtimeListening => _presetService.isListening;

  Future<void> restartRealtimeListeners() async {
    await _presetService.restartListeners();
    handleRealtimeUpdate();
  }
}
