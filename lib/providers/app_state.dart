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
  String _dataSource = "live"; // "live" or "post"
  bool _isLoading = false;
  int _selectedIndex = 0; // Track selected preset index (exactly like legacy app)
  bool _stayMinimizedDuringCapture = false;
  String _presetPassword = '';

  // Getters
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

  // Initialize the app state
  void initialize() {
    // Set up real-time callback
    _presetService.setDataChangedCallback(handleRealtimeUpdate);
    
    _authService.userStream.listen((user) {
      _currentUser = user;
      if (user != null) {
        _loadUserData();
        _loadUserSettings();
      } else {
        _presets.clear();
        _collections.clear();
        _presetPassword = '';
      }
      notifyListeners();
    });
  }

  // Load user data from Firebase
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

  // Load user-level settings like presetPassword from /users/{uid}
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

  // Toggle dark mode
  void toggleDarkMode() {
    _isDarkMode = !_isDarkMode;
    notifyListeners();
  }

  // Toggle no effects
  void toggleNoEffects() {
    _noEffectsEnabled = !_noEffectsEnabled;
    notifyListeners();
  }

  // Set selected index (exactly like legacy app)
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

  // Create "No Effects" preset (exactly like legacy app)
  Preset createNoEffectsPreset() {
    return Preset(
      title: "No Effects",
      name: "No Effects",
      presetId: "no_effects_virtual",
      collectionId: "virtual",
      isNoEffects: true,
    );
  }

  // Set data source
  void setDataSource(String source) {
    print("🔄 AppState: Switching data source from '$_dataSource' to '$source'");
    _dataSource = source;
    
    // Force re-categorization of presets based on URLs
    _presetService.recategorizePresets();
    
    _presets = _presetService.getPresetsForDataSource(_dataSource);
    _collections = _presetService.getCollectionsForDataSource(_dataSource);
    
    print("🔄 AppState: After switch - ${_presets.length} presets, ${_collections.length} collections");
    
    // Update data source in PresetService and restart listeners
    _presetService.updateDataSource(_dataSource);
    
    notifyListeners();
  }

  // Add preset
  Future<void> addPreset(Preset preset) async {
    try {
      final newPreset = await _presetService.addPreset(preset);
      _presets = _presetService.getPresetsForDataSource(_dataSource);
      notifyListeners();
    } catch (e) {
      debugPrint('Error adding preset: $e');
    }
  }

  // Update preset
  Future<void> updatePreset(int index, Preset preset) async {
    try {
      await _presetService.updatePreset(index, preset);
      _presets = _presetService.getPresetsForDataSource(_dataSource);
      notifyListeners();
    } catch (e) {
      debugPrint('Error updating preset: $e');
    }
  }

  // Delete preset
  Future<void> deletePreset(int index) async {
    try {
      await _presetService.deletePreset(index);
      _presets = _presetService.getPresetsForDataSource(_dataSource);
      notifyListeners();
    } catch (e) {
      debugPrint('Error deleting preset: $e');
    }
  }

  // Add collection - exactly like legacy app
  Future<void> addCollection(Collection collection) async {
    try {
      // Generate random collection ID (8 characters) - exactly like legacy
      final collectionId = _generateRandomId(8);
      
      // Create collection in Firebase - exactly like legacy app
      await _presetService.createCollectionInFirebase(collection.name, collectionId);
      
      // Add to local collections
      _collections.add(collection);
      
      // Refresh collections from Firebase to get the latest data
      await _presetService.initialize();
      _collections = _presetService.getCollectionsForDataSource(_dataSource);
      
      notifyListeners();
    } catch (e) {
      debugPrint('Error adding collection: $e');
    }
  }

  // Generate random ID like legacy app
  String _generateRandomId(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(
      Iterable.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  // Update collection
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

  // Delete collection
  Future<void> deleteCollection(String collectionName) async {
    try {
      await _authService.deleteCollection(collectionName);
      _collections.removeWhere((c) => c.name == collectionName);
      notifyListeners();
    } catch (e) {
      debugPrint('Error deleting collection: $e');
    }
  }

  // Sign in with email and password
  Future<void> signInWithEmailAndPassword(String email, String password) async {
    try {
      await _authService.signInWithEmailAndPassword(email, password);
      // User state will be updated by the auth state listener
    } catch (e) {
      debugPrint('Error signing in: $e');
      rethrow;
    }
  }

  // Sign in with Google
  Future<void> signInWithGoogle() async {
    try {
      await _authService.signInWithGoogle();
      // User state will be updated by the auth state listener
    } catch (e) {
      debugPrint('Error signing in with Google: $e');
      rethrow;
    }
  }

  // Sign out
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

  // Navigate to saved presets
  void navigateToSavedPresets() {
    // TODO: Implement navigation to saved presets screen
    debugPrint('Navigate to saved presets');
  }

  // Set loading state
  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  // ===== REAL-TIME UPDATES =====
  
  /// Handle real-time updates from Firebase listeners
  void handleRealtimeUpdate() {
    print("🔄 AppState: Handling real-time update from Firebase");
    
    // Refresh data from PresetService
    _presets = _presetService.getPresetsForDataSource(_dataSource);
    _collections = _presetService.getCollectionsForDataSource(_dataSource);
    
    // Notify UI of changes
    notifyListeners();
    
    print("✅ AppState: Updated with ${_presets.length} presets and ${_collections.length} collections");
  }

  /// Check if real-time listeners are active
  bool get isRealtimeListening => _presetService.isListening;

  /// Restart real-time listeners (useful when switching data sources)
  Future<void> restartRealtimeListeners() async {
    await _presetService.restartListeners();
    handleRealtimeUpdate();
  }
}
