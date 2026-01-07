import 'package:flutter/material.dart';
import 'dart:math';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user.dart' as app_user;
import '../models/preset.dart';
import '../models/collection.dart';
import '../services/auth_service.dart';
import '../services/preset_service.dart';
import '../services/session_service.dart';

class AppState extends ChangeNotifier {
  final AuthService _authService = AuthService();
  final PresetService _presetService = PresetService();
  
  StreamSubscription<app_user.User?>? _userStreamSubscription;
  
  app_user.User? _currentUser;
  List<Preset> _presets = [];
  List<Collection> _collections = [];
  bool _noEffectsEnabled = false;
  String _dataSource = "live";
  bool _isLoading = false;
  int _selectedIndex = 0;
  bool _stayMinimizedDuringCapture = false;
  String _presetPassword = '';

  app_user.User? get currentUser => _currentUser;
  List<Preset> get presets => _presets;
  List<Collection> get collections => _collections;
  bool get noEffectsEnabled => _noEffectsEnabled;
  String get dataSource => _dataSource;
  bool get isLoading => _isLoading;
  int get selectedIndex => _selectedIndex;
  bool get stayMinimizedDuringCapture => _stayMinimizedDuringCapture;
  String get presetPassword => _presetPassword;

  void initialize() {
    print('AppState:initialize');
    _presetService.setDataChangedCallback(handleRealtimeUpdate);
    
    _userStreamSubscription?.cancel();
    _userStreamSubscription = _authService.userStream.listen((user) async {
      _currentUser = user;
      if (user != null) {
        print('AppState:user signed in ${user.uid}');
        await SessionService.clearSession();
        await Future.delayed(const Duration(milliseconds: 500));
        _loadUserData();
        _loadUserSettings();
      } else {
        print('AppState:user signed out');
        await SessionService.clearSession();
        _presets.clear();
        _collections.clear();
        _presetPassword = '';
      }
      notifyListeners();
    });
  }
  
  @override
  void dispose() {
    _userStreamSubscription?.cancel();
    _userStreamSubscription = null;
    super.dispose();
  }

  Future<void> _loadUserData() async {
    if (_currentUser == null) return;
    
    _setLoading(true);
    try {
      await _presetService.initialize();
      _presets = _presetService.getPresetsForDataSource(_dataSource);
      _collections = _presetService.getCollectionsForDataSource(_dataSource);
      print("✅ AppState: Loaded ${_presets.length} presets and ${_collections.length} collections for data source '$_dataSource'");
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading user data: $e');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _loadUserSettings() async {
    try {
      final user = _currentUser;
      if (user == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (_currentUser == null || _currentUser!.uid != user.uid) return;
      
      if (!doc.exists) {
        print("📁 User document doesn't exist yet - this is normal for new users");
        _presetPassword = '';
        return;
      }
      
      final data = doc.data();
      if (data != null) {
        _presetPassword = (data['presetPassword'] ?? '') as String;
        notifyListeners();
      }
    } catch (e) {
      final errorString = e.toString().toLowerCase();
      if (errorString.contains('permission-denied') || 
          errorString.contains('missing or insufficient permissions')) {
        debugPrint('⚠️ Permission denied loading user settings - user may not be fully authenticated yet');
      } else if (errorString.contains('internal') || 
                 errorString.contains('server error')) {
        debugPrint('⚠️ Internal server error loading user settings - user document may not exist yet (normal for new users)');
      } else {
        debugPrint('Error loading user settings: $e');
      }
    }
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
      await _presetService.resetUserState();
      notifyListeners();
    } catch (e) {
      debugPrint('Error signing out: $e');
    }
  }


  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void handleRealtimeUpdate() {
    print("🔄 AppState: Handling real-time update from Firebase");
    
    _presets = _presetService.getPresetsForDataSource(_dataSource);
    _collections = _presetService.getCollectionsForDataSource(_dataSource);

    if (_presets.isEmpty) {
      _selectedIndex = 0;
    } else if (_selectedIndex < 0) {
      _selectedIndex = 0;
    } else if (_selectedIndex >= _presets.length) {
      _selectedIndex = _presets.length - 1;
    }
    
    notifyListeners();
    
    print("✅ AppState: Updated with ${_presets.length} presets and ${_collections.length} collections");
  }

  bool get isRealtimeListening => _presetService.isListening;

  Future<void> restartRealtimeListeners() async {
    await _presetService.restartListeners();
    handleRealtimeUpdate();
  }
}
