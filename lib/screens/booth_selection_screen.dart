import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../services/preset_service.dart';
import '../services/log_service.dart';
import '../services/session_service.dart';
import '../providers/app_state.dart';
import '../models/preset.dart';
import '../widgets/chevron_widget.dart';
import '../services/thumbnail_cache_service.dart';

class _SmoothPageScrollPhysics extends PageScrollPhysics {
  const _SmoothPageScrollPhysics({super.parent});

  @override
  _SmoothPageScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _SmoothPageScrollPhysics(parent: buildParent(ancestor));
  }

  @override
  SpringDescription get spring => const SpringDescription(
        mass: 0.95,
        stiffness: 260.0,
        damping: 30.0,
      );
}

class BoothSelectionScreen extends StatefulWidget {
  const BoothSelectionScreen({super.key, this.collectionFilter});

  final String? collectionFilter;

  @override
  State<BoothSelectionScreen> createState() => _BoothSelectionScreenState();
}

class _BoothSelectionScreenState extends State<BoothSelectionScreen>
    with SingleTickerProviderStateMixin, WindowListener {

  static const double _baseWidth = 1920;
  static const double _baseHeight = 1080;
  List<Preset> _currentPresets = [];
  int _selectedIndex = 0;
  final ScrollController _scrollController = ScrollController();
  final PageController _portraitPageController = PageController();
  int _portraitPage = 0;
  Timer? _portraitWheelTimer;
  bool _portraitAnimating = false;
  int? _portraitTargetPage;
  bool _showPortraitScrollbar = false;
  Timer? _portraitScrollbarTimer;
  bool _portraitDragTriggered = false;
  double _portraitDragDy = 0.0;
  final FocusNode _focusNode = FocusNode();
  Timer? _snapTimer;
  Timer? _coalesceTimer;
  Timer? _workerPollTimer;
  Timer? _donePollTimer;
  bool _minimizing = false;
  String? _activeSessionToken;
  bool _focusLockEnabled = false;
  Timer? _focusLockTimer;
  bool _forcingFocus = false;

  int _lastAllPresetsCount = -1;
  final Map<String, List<Preset>> _presetsByCollection = <String, List<Preset>>{};
  List<Preset> _allPresetsSnapshot = <Preset>[];

  static const double baseWidth = 600.0;
  static const double baseHeight = 600.0;
  static const double aspectRatio = 1.0;
  static const double minWidth = 550.0;
  static const double maxWidth = 700.0;
  static const double gap = 80.0;
  static const double gapLandscape = 30.0;
  static const double gapPortrait = 12.0;
  static const double sidePaddingPortrait = 6.0;
  static const double portraitHeightFactor = 1.32;
  static const double wheelSpeed = 0.28;
  static const int minDuration = 300;
  static const int maxDuration = 800;
  static const int snapDuration = 300;
  static const int snapDurationLandscape = 300;
  static const int snapIdle = 100;
  static const double snapHysteresis = 0.30;

  bool _isUserScrolling = false;

  double _getGap() {
    if (!mounted) return gap;
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.landscape) {
      return gapLandscape;
    } else {
      return gapPortrait;
    }
  }
  bool _showLeftArrow = false;
  bool _showRightArrow = false;

  double _cardWidth = baseWidth;
  double _cardHeight = baseHeight;
  double _scrollStep = 0.0;
  bool _hasPostDeliveryPreset = false;

  @override
  void initState() {
    super.initState();


    assert(() {
      debugPrint('BoothSelectionScreen:init');
      return true;
    }());
    _selectedIndex = 0;
    _scrollController.addListener(_onScroll);
    if (Platform.isWindows) {
      windowManager.addListener(this);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _updateArrows();
      _calculateResponsiveCardSize();
      _setFullscreenFrameless();

      assert(() {
        debugPrint('BoothSelectionScreen:postFrame ready');
        return true;
      }());
      _initPresetsFromFilter();
    });
  }
  
  void _enableFocusLock() {
    if (!Platform.isWindows) return;
    if (_focusLockEnabled) return;
    _focusLockEnabled = true;

    _focusLockTimer?.cancel();
    _focusLockTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!mounted) return;
      if (_focusLockEnabled) {
        unawaited(_reassertFocus());
      }
    });

    unawaited(_reassertFocus());
  }

  Future<void> _disableFocusLock() async {
    if (!Platform.isWindows) return;
    _focusLockEnabled = false;
    _focusLockTimer?.cancel();
    _focusLockTimer = null;
    try {
      await windowManager.setAlwaysOnTop(false);
    } catch (_) {}
  }

  Future<void> _safeWindowCall(
    String label,
    Future<void> Function() action, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    try {
      await action().timeout(timeout);
    } catch (e) {
      await LogService.log('BoothSelectionScreen: $label failed: $e');
    }
  }

  Future<void> _forceResetUi() async {
    if (!mounted) return;
    await LogService.log('BoothSelectionScreen: force reset');
    _focusLockEnabled = false;
    _focusLockTimer?.cancel();
    _focusLockTimer = null;
    _restoring = false;
    _restoreStartTime = null;
    _minimizing = false;

    await SessionService.clearWorkerDone();
    await SessionService.clearDonePressed();
    await SessionService.clearPendingSessionEnd();
    await SessionService.setActiveSessionPhase(SessionService.phaseIdle);

    if (!mounted) return;
    final appState = Provider.of<AppState>(context, listen: false);
    appState.setStayMinimizedDuringCapture(false);

    if (!Platform.isWindows) return;
    await _safeWindowCall('reset: alwaysOnTop off', () => windowManager.setAlwaysOnTop(false));
    await _safeWindowCall('reset: opacity', () => windowManager.setOpacity(1.0));
    await _safeWindowCall('reset: restore', () => windowManager.restore());
    await _safeWindowCall('reset: show', () => windowManager.show());
    await _safeWindowCall('reset: focus', () => windowManager.focus());
    await _safeWindowCall('reset: fullscreen', () => windowManager.setFullScreen(true));
  }

  Future<void> _reassertFocus() async {
    if (!Platform.isWindows) return;
    if (!mounted) return;
    if (_forcingFocus) return;
    if (_minimizing) return;
    if (_restoring) return;
    _forcingFocus = true;
    try {
      final phase = await SessionService.getActiveSessionPhase();
      if (phase != SessionService.phaseIdle) {
        return;
      }
      await _safeWindowCall('reassert: alwaysOnTop', () => windowManager.setAlwaysOnTop(true));
      await _safeWindowCall('reassert: restore', () => windowManager.restore());
      await _safeWindowCall('reassert: show', () => windowManager.show());
      await Future.delayed(const Duration(milliseconds: 16));
      await _safeWindowCall('reassert: focus', () => windowManager.focus());
      await _safeWindowCall('reassert: fullscreen', () => windowManager.setFullScreen(true));
    } catch (e) {
      await LogService.log('BoothSelectionScreen: focus lock reassert failed: $e');
    } finally {
      _forcingFocus = false;
    }
  }

  @override
  void onWindowBlur() {
    if (!_focusLockEnabled) return;
    unawaited(_reassertFocus());
  }
  
  Future<void> _setFullscreenFrameless() async {
    if (Platform.isWindows) {
      try {
      await windowManager.setFullScreen(true);
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      } catch (e) {
        await LogService.log('BoothSelectionScreen: _setFullscreenFrameless failed: $e');
      }
    }
  }

  void _calculateResponsiveCardSize() {
    if (!mounted) return;
    
    final screenWidth = MediaQuery.of(context).size.width;
    final orientation = MediaQuery.of(context).orientation;
    
    if (orientation == Orientation.portrait) {
      const visibleCols = 3;
      final currentGap = _getGap();
      final totalGaps = (visibleCols - 1) * currentGap;
      final availableWidth = screenWidth - totalGaps - (sidePaddingPortrait * 2);
      final calculatedWidth = availableWidth / visibleCols;

      _cardWidth = math.max(140.0, calculatedWidth);
      _cardHeight = _cardWidth * portraitHeightFactor;
    } else {

      const maxVisibleCols = 3;
      final currentGap = _getGap();
      final totalGaps = (maxVisibleCols - 1) * currentGap;
      
      final availableWidth = screenWidth - totalGaps;
      final calculatedWidth = availableWidth / maxVisibleCols;

      _cardWidth = math.max(minWidth, calculatedWidth);
      _cardHeight = _cardWidth;
    }
    
    _scrollStep = _cardWidth + _getGap();
    
    setState(() {});
  }

  String _labelForPreset(Preset preset) {

    final type = (preset.postProcessingUrl.toLowerCase().contains('post-delivery'))
        ? 'post-delivery'
        : 'live';
    return type;
  }

  void _initPresetsFromFilter() {
    final appState = Provider.of<AppState>(context, listen: false);

    final presetService = PresetService();
    final allPresets = <Preset>[
      ...presetService.localPresets,
      ...presetService.localPostDeliveryPresets,
    ];

    if (allPresets.length != _lastAllPresetsCount) {
      _lastAllPresetsCount = allPresets.length;
      _allPresetsSnapshot = allPresets;
      _presetsByCollection.clear();
      for (final p in allPresets) {
        final key = p.collection;
        if (key.isEmpty) continue;
        (_presetsByCollection[key] ??= <Preset>[]).add(p);
      }
    }

    final String? filter = widget.collectionFilter;
    List<Preset> list;
    if (filter == null) {
      list = List<Preset>.of(_allPresetsSnapshot);
    } else {
      list = List<Preset>.of(_presetsByCollection[filter] ?? const <Preset>[]);
    }

    if (appState.noEffectsEnabled) {
      final noEffectsPreset = _createNoEffectsPreset();
      list.insert(0, noEffectsPreset);
    }

    setState(() {
      _currentPresets = list;
      _selectedIndex = _currentPresets.isNotEmpty ? 0 : -1;
      _portraitPage = 0;
      _portraitTargetPage = 0;
      _hasPostDeliveryPreset = list.any(
        (p) => p.postProcessingUrl.toLowerCase().contains('post-delivery'),
      );
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateArrows();
      if (!mounted) return;
      if (_portraitPageController.hasClients) {
        _portraitPageController.jumpToPage(0);
      }
    });
  }

  @override
  void dispose() {
    _snapTimer?.cancel();
    _coalesceTimer?.cancel();
    _workerPollTimer?.cancel();
    _donePollTimer?.cancel();
    _focusLockTimer?.cancel();
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _portraitWheelTimer?.cancel();
    _portraitScrollbarTimer?.cancel();
    _portraitPageController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  int _portraitPageCount() {
    if (_currentPresets.isEmpty) return 0;
    return ((_currentPresets.length + 5) / 6).floor();
  }

  double _portraitTileHeight() {
    final caption = _hasPostDeliveryPreset ? 64.0 : 44.0;
    return _cardHeight + caption;
  }

  void _bumpPortraitScrollbar() {
    if (!mounted) return;
    if (!_showPortraitScrollbar) {
      setState(() {
        _showPortraitScrollbar = true;
      });
    }
    _portraitScrollbarTimer?.cancel();
    _portraitScrollbarTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      if (_showPortraitScrollbar) {
        setState(() {
          _showPortraitScrollbar = false;
        });
      }
    });
  }

  void _setPortraitPage(int page) {
    final pageCount = _portraitPageCount();
    if (pageCount <= 0) return;
    final nextPage = page.clamp(0, pageCount - 1);
    if (nextPage == _portraitPage) return;
    setState(() {
      _portraitPage = nextPage;
      final startIdx = _portraitPage * 6;
      if (_currentPresets.isNotEmpty) {
        _selectedIndex = math.min(_currentPresets.length - 1, startIdx);
      }
    });
  }

  int _clampPortraitPage(int page) {
    final pageCount = _portraitPageCount();
    if (pageCount <= 0) return 0;
    return page.clamp(0, pageCount - 1);
  }

  Duration _portraitAnimDuration({required int from, required int to}) {
    final distance = (to - from).abs().clamp(1, 4);
    final ms = (520 + (distance - 1) * 220).clamp(520, 1100);
    return Duration(milliseconds: ms);
  }

  int _portraitCurrentPage() {
    if (_portraitPageController.hasClients) {
      final p = _portraitPageController.page;
      if (p != null) return p.round();
    }
    return _portraitPage;
  }

  void _snapPortraitToNearestPage() {
    if (!_portraitPageController.hasClients) return;
    final raw = _portraitPageController.page ?? _portraitPage.toDouble();
    final nearest = _clampPortraitPage(raw.round());
    _setPortraitPage(nearest);
    _portraitTargetPage = nearest;
    unawaited(_runPortraitPageAnimationLoop());
  }

  Future<void> _runPortraitPageAnimationLoop() async {
    if (_portraitAnimating) return;
    if (!_portraitPageController.hasClients) return;
    _portraitAnimating = true;
    try {
      while (mounted) {
        final target = _portraitTargetPage;
        if (target == null) break;

        final currentPage = (_portraitPageController.page ?? _portraitPage.toDouble()).round();
        final clampedTarget = _clampPortraitPage(target);
        if (currentPage == clampedTarget) {
          _portraitTargetPage = null;
          break;
        }

        await _portraitPageController.animateToPage(
          clampedTarget,
          duration: _portraitAnimDuration(from: currentPage, to: clampedTarget),
          curve: Curves.easeInOutCubic,
        );
      }
    } finally {
      _portraitAnimating = false;
    }
  }

  Future<void> _scrollPortraitPage(int deltaPages) async {
    final pageCount = _portraitPageCount();
    if (pageCount <= 1) return;

    final current = _portraitCurrentPage();
    final nextPage = (current + deltaPages).clamp(0, pageCount - 1);
    if (nextPage == current) return;

    if (!_portraitPageController.hasClients) {
      _portraitTargetPage = nextPage;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_portraitPageController.hasClients) return;
        unawaited(_runPortraitPageAnimationLoop());
      });
      return;
    }

    _setPortraitPage(nextPage);
    _portraitTargetPage = nextPage;
    unawaited(_runPortraitPageAnimationLoop());
  }

  void _onScroll() {
    _updateArrows();

    final orientation = MediaQuery.of(context).orientation;
    if (_scrollController.hasClients && _currentPresets.isNotEmpty) {
      final vpw = MediaQuery.of(context).size.width;
      final step = _scrollStep;
      
      final itemCount = _currentPresets.length;
      if (orientation == Orientation.portrait) {

        final center = _scrollController.offset + vpw / 2.0;
        final horizontalPadding = (vpw - _cardWidth) / 2.0;
        final cardCenterOffset = horizontalPadding + _cardWidth / 2.0;
        final relativeOffset = center - cardCenterOffset;
        final idxFloat = relativeOffset / step;
        final centeredIdx = math.max(0, math.min(itemCount - 1, idxFloat.round()));
        
        if (centeredIdx != _selectedIndex) {
          setState(() {
            _selectedIndex = centeredIdx;
          });
        }
      } else {

        final horizontalPadding = (vpw - _cardWidth) / 2.0;
        final screenCenter = _scrollController.offset + vpw / 2.0;
        final relativeCenter = screenCenter - horizontalPadding;
        final idxFloat = (relativeCenter - _cardWidth / 2.0) / step;
        final centeredIdx = math.max(0, math.min(itemCount - 1, idxFloat.round()));
        
        if (centeredIdx != _selectedIndex) {
          setState(() {
            _selectedIndex = centeredIdx;
          });
        }
      }
    }

    _isUserScrolling = true;
    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(const Duration(milliseconds: snapIdle), () {
      _isUserScrolling = false;
      _snapToCardSmooth();
    });
  }

  void _updateArrows() {
    if (!_scrollController.hasClients) return;
    
    final canScroll = _scrollController.position.maxScrollExtent > 0.5;
    final atMin = _scrollController.offset <= _scrollController.position.minScrollExtent + 1;
    final atMax = _scrollController.offset >= _scrollController.position.maxScrollExtent - 1;
    
    setState(() {
      _showLeftArrow = canScroll && !atMin;
      _showRightArrow = canScroll && !atMax;
    });
  }

  void _snapToCard({bool hysteresis = false}) {
    if (!_scrollController.hasClients) return;
    
    final orientation = MediaQuery.of(context).orientation;
    final vpw = MediaQuery.of(context).size.width;
    final step = _scrollStep;
    
    final itemCount = _currentPresets.length;
    if (orientation == Orientation.portrait) {

      final center = _scrollController.offset + vpw / 2.0;
      final horizontalPadding = (vpw - _cardWidth) / 2.0;
      final cardCenterOffset = horizontalPadding + _cardWidth / 2.0;
      final relativeOffset = center - cardCenterOffset;
      final idxFloat = relativeOffset / step;
      final clampedIdx = math.max(0, math.min(itemCount - 1, idxFloat.round()));

      if (clampedIdx != _selectedIndex) {
        setState(() {
          _selectedIndex = clampedIdx;
        });
      }

      final target = horizontalPadding + clampedIdx * step + _cardWidth / 2.0 - vpw / 2.0;
      final clampedTarget = math.max(
        0.0,
        math.min(_scrollController.position.maxScrollExtent, target),
      );
      
      _animateTo(clampedTarget, duration: snapDurationLandscape);
    } else {

      final horizontalPadding = (vpw - _cardWidth) / 2.0;
      final screenCenter = _scrollController.offset + vpw / 2.0;
      final relativeCenter = screenCenter - horizontalPadding;
      final idxFloat = (relativeCenter - _cardWidth / 2.0) / step;
      
      int idx;
      if (hysteresis) {
        final idxFloor = idxFloat.floor();
        final frac = idxFloat - idxFloor;
        if (frac > (1.0 - snapHysteresis)) {
          idx = idxFloor + 1;
        } else if (frac < snapHysteresis) {
          idx = idxFloor;
        } else {
          idx = idxFloat.round();
        }
      } else {
        idx = idxFloat.round();
      }
      
      idx = math.max(0, math.min(itemCount - 1, idx));
      
      if (idx != _selectedIndex) {
        setState(() {
          _selectedIndex = idx;
        });
      }
      
      final target = horizontalPadding + idx * step + _cardWidth / 2.0 - vpw / 2.0;
      final clampedTarget = math.max(
        0.0,
        math.min(_scrollController.position.maxScrollExtent, target),
      );
      
      _animateTo(clampedTarget, duration: snapDurationLandscape);
    }
  }

  void _snapToCardSmooth() {
    if (!_scrollController.hasClients) return;
    
    final orientation = MediaQuery.of(context).orientation;
    final vpw = MediaQuery.of(context).size.width;
    final step = _scrollStep;
    final horizontalPadding = (vpw - _cardWidth) / 2.0;
    
    final itemCount = _currentPresets.length;
    int targetIdx;
    
    if (orientation == Orientation.portrait) {
      final center = _scrollController.offset + vpw / 2.0;
      final cardCenterOffset = horizontalPadding + _cardWidth / 2.0;
      final relativeOffset = center - cardCenterOffset;
      final idxFloat = relativeOffset / step;
      targetIdx = math.max(0, math.min(itemCount - 1, idxFloat.round()));
    } else {
      final screenCenter = _scrollController.offset + vpw / 2.0;
      final relativeCenter = screenCenter - horizontalPadding;
      final idxFloat = (relativeCenter - _cardWidth / 2.0) / step;
      
      final idxFloor = idxFloat.floor();
      final frac = idxFloat - idxFloor;
      if (frac > (1.0 - snapHysteresis)) {
        targetIdx = idxFloor + 1;
      } else if (frac < snapHysteresis) {
        targetIdx = idxFloor;
      } else {
        targetIdx = idxFloat.round();
      }
      targetIdx = math.max(0, math.min(itemCount - 1, targetIdx));
    }
    
    if (targetIdx != _selectedIndex) {
      setState(() {
        _selectedIndex = targetIdx;
      });
    }
    
    final target = horizontalPadding + targetIdx * step + _cardWidth / 2.0 - vpw / 2.0;
    final clampedTarget = math.max(
      0.0,
      math.min(_scrollController.position.maxScrollExtent, target),
    );
    
    final currentOffset = _scrollController.offset;
    final distance = (clampedTarget - currentOffset).abs();
    
    if (distance < 0.5) return;
    
    final normalized = math.min(1.0, distance / 1200.0);
    final eased = math.pow(normalized, 0.5) as double;
    
    final baseDuration = math.max(150, math.min(400, (distance / 3.0).round()));
    final duration = (baseDuration + (maxDuration - baseDuration) * eased).toInt();
    final actualDuration = math.max(150, math.min(maxDuration, duration));
    
    _scrollController.animateTo(
      clampedTarget,
      duration: Duration(milliseconds: actualDuration),
      curve: Curves.easeOutCubic,
    );
  }

  void _animateTo(double target, {int? duration}) {
    if (!_scrollController.hasClients) return;
    
    final start = _scrollController.offset;
    final distance = (target - start).abs();

    if (distance < 0.5) return;
    
    final actualDuration = duration ?? _calculateDuration(start, target);

    final curve = Curves.easeOutQuart;
    
    _scrollController.animateTo(
      target,
      duration: Duration(milliseconds: actualDuration),
      curve: curve,
    );
  }

  int _calculateDuration(double start, double target) {
    final dist = (target - start).abs();

    final normalized = math.min(1.0, dist / 1200.0);

    final eased = math.pow(normalized, 0.5) as double;
    final duration = (minDuration + (maxDuration - minDuration) * eased).toInt();
    return math.max(minDuration, math.min(maxDuration, duration));
  }

  void _scrollBy(int steps) {
    if (!_scrollController.hasClients) return;
    
    final orientation = MediaQuery.of(context).orientation;
    final vpw = MediaQuery.of(context).size.width;
    final horizontalPadding = (vpw - _cardWidth) / 2.0;
    
    final newCardIndex = math.max(
      0,
      math.min(
        _currentPresets.length - 1,
        _selectedIndex + steps,
      ),
    );
    
    final target = horizontalPadding + newCardIndex * _scrollStep + _cardWidth / 2.0 - vpw / 2.0;
    final clampedTarget = math.max(
      0.0,
      math.min(
        _scrollController.position.maxScrollExtent,
        target,
      ),
    );
    
    if (newCardIndex != _selectedIndex) {
      setState(() {
        _selectedIndex = newCardIndex;
      });
    }
    
    _animateTo(clampedTarget);

    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(const Duration(milliseconds: snapIdle), () {
      _snapToCardSmooth();
    });
  }

  Preset _createNoEffectsPreset() {
    return Preset(
      presetId: 'no_effects',
      collectionId: '',
      name: 'No Effects',
      title: 'No Effects',
      url: '',
      postProcessingUrl: '',

      generatedImageUrls: '',
      collection: 'No Effects',
      thumbnailPath: '',
      createdAt: DateTime.now().millisecondsSinceEpoch.toString(),
      isNoEffects: true,
    );
  }

  void _onTakePicture(BuildContext context) async {
    if (!mounted) return;
    
    final appState = Provider.of<AppState>(context, listen: false);
    await _disableFocusLock();
    if (_currentPresets.isEmpty) {
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Photo booth mode activated! Waiting for images...'),
        backgroundColor: Color(0xFFCC66FF),
        duration: Duration(seconds: 2),
      ),
    );

    appState.setStayMinimizedDuringCapture(true);

    final safeIndex = _selectedIndex.clamp(0, _currentPresets.length - 1);
    final preset = _currentPresets[safeIndex];
    await SessionService.saveSelectedPreset(preset, presetPassword: appState.presetPassword);
    if (!mounted) return;

    await SessionService.clearWorkerDone();
    await SessionService.clearDonePressed();
    await SessionService.clearPendingSessionEnd();

    if (Platform.isWindows) {
      if (_minimizing) return;
      _minimizing = true;
      try {
        if (!mounted) return;
        await _safeWindowCall('minimize: opacity', () => windowManager.setOpacity(0.0));
        if (!mounted) return;
        await Future.delayed(const Duration(milliseconds: 16));
        if (!mounted) return;
        final isFS = await windowManager.isFullScreen().timeout(const Duration(seconds: 1));
        if (!mounted) return;
        if (isFS) {
          await _safeWindowCall('minimize: fullscreen off', () => windowManager.setFullScreen(false));
          if (!mounted) return;
          await Future.delayed(const Duration(milliseconds: 16));
        }
        if (!mounted) return;
        await _safeWindowCall('minimize: minimize', () => windowManager.minimize());
      } catch (e) {
        assert(() {
          debugPrint('âš ï¸ Failed to minimize window');
          return true;
        }());
        await LogService.log('BoothSelectionScreen: minimize failed: $e');
        await _safeWindowCall('minimize: hide fallback', () => windowManager.hide());
        await _safeWindowCall('minimize: opacity fallback', () => windowManager.setOpacity(0.0));
      } finally {
        _minimizing = false;
      }
    }

    _activeSessionToken = await SessionService.startSession();
    if (!mounted) return;

    if (preset.isNoEffects) {
      await SessionService.setActiveSessionPhase(SessionService.phaseWaitingSessionEnd);
      if (mounted) {
        _startDonePressedPolling(appState);
      }
      return;
    }

    _startWorkerCompletionPolling(appState);
  }
  
  void _startWorkerCompletionPolling(AppState appState) {
    _workerPollTimer?.cancel();
    _workerPollTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final phase = await SessionService.getActiveSessionPhase();
      if (phase != SessionService.phaseCapturing) {
        return;
      }

      final token = _activeSessionToken;
      final isDone = token != null
          ? await SessionService.checkWorkerDoneToken(token)
          : await SessionService.checkWorkerDone();
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      if (isDone) {
        timer.cancel();
        await SessionService.clearWorkerDone();
        await SessionService.setActiveSessionPhase(SessionService.phaseWaitingSessionEnd);
        final pending = await SessionService.hasPendingSessionEnd();
        if (pending) {
          await SessionService.clearPendingSessionEnd();
          final token = _activeSessionToken;
          if (token != null) {
            await SessionService.signalDonePressedToken(token);
          } else {
            await SessionService.signalDonePressed();
          }
        }
        if (mounted) {
          _startDonePressedPolling(appState);
        }
      }
    });
  }


  bool _restoring = false;
  DateTime? _restoreStartTime;
  static const Duration _restoreTimeout = Duration(seconds: 5);

  Future<void> _restoreSeamless(AppState appState) async {
    if (_restoring) {
      final elapsed = _restoreStartTime != null 
          ? DateTime.now().difference(_restoreStartTime!)
          : Duration.zero;
      if (elapsed > _restoreTimeout) {
        await LogService.log('BoothSelectionScreen:restore timeout exceeded, resetting restoring flag');
        _restoring = false;
        _restoreStartTime = null;
      } else {
        return;
      }
    }
    
    _restoring = true;
    _restoreStartTime = DateTime.now();
    
    bool alwaysOnTopSet = false;
    
    try {
      if (!mounted) {
        return;
      }

      await _safeWindowCall('restore: alwaysOnTop on', () => windowManager.setAlwaysOnTop(true));
      alwaysOnTopSet = true;

      await _safeWindowCall('restore: opacity 0', () => windowManager.setOpacity(0.0));
      await _safeWindowCall('restore: restore', () => windowManager.restore());
      await _safeWindowCall('restore: show', () => windowManager.show());
      await Future.delayed(const Duration(milliseconds: 20));
      await _safeWindowCall('restore: focus', () => windowManager.focus());
      await Future.delayed(const Duration(milliseconds: 20));
      await _safeWindowCall('restore: fullscreen on', () => windowManager.setFullScreen(true));
      await Future.delayed(const Duration(milliseconds: 60));
      await _safeWindowCall('restore: opacity 1', () => windowManager.setOpacity(1.0));
      
      await Future.delayed(const Duration(milliseconds: 200));
      
      if (mounted && !_focusLockEnabled) {
        await _safeWindowCall('restore: alwaysOnTop off', () => windowManager.setAlwaysOnTop(false));
        alwaysOnTopSet = false;
      }
      
    } catch (e, stack) {
      await LogService.log('BoothSelectionScreen: error restoring window: $e');
      await LogService.log('BoothSelectionScreen: restore stack: $stack');
    } finally {
      try {
        await _safeWindowCall('restore: final opacity', () => windowManager.setOpacity(1.0));
        if (alwaysOnTopSet && mounted && !_focusLockEnabled) {
          await _safeWindowCall('restore: final alwaysOnTop off', () => windowManager.setAlwaysOnTop(false));
        }
        if (mounted) {
          appState.setStayMinimizedDuringCapture(false);
        }
      } catch (e) {
        await LogService.log('BoothSelectionScreen: error resetting window state: $e');
      } finally {
        _restoring = false;
        _restoreStartTime = null;
      }
    }
  }

  void _startDonePressedPolling(AppState appState) {
    _donePollTimer?.cancel();
    _donePollTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final token = _activeSessionToken;
      final pressed = token != null
          ? await SessionService.checkDonePressedToken(token)
          : await SessionService.checkDonePressed();
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      if (pressed) {
        timer.cancel();
        await SessionService.clearDonePressed();
        
        await SessionService.setActiveSessionPhase(SessionService.phaseIdle);
        
        if (!mounted) {
          return;
        }
        
        if (Platform.isWindows) {
          _enableFocusLock();
          await _restoreSeamless(appState);
        }
      }
    });
  }

  void _handleEscKey() async {
    Navigator.of(context).pop();
  }

  void _onBack() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: (KeyEvent event) {
        if (event is KeyDownEvent) {
          final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            _handleEscKey();
          } else if (event.logicalKey == LogicalKeyboardKey.f12) {
            unawaited(_forceResetUi());
          } else if (isPortrait && (event.logicalKey == LogicalKeyboardKey.arrowDown || event.logicalKey == LogicalKeyboardKey.pageDown)) {
            _scrollPortraitPage(1);
          } else if (isPortrait && (event.logicalKey == LogicalKeyboardKey.arrowUp || event.logicalKey == LogicalKeyboardKey.pageUp)) {
            _scrollPortraitPage(-1);
          } else if (!isPortrait && event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _scrollBy(1);
          } else if (!isPortrait && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _scrollBy(-1);
          } else if (!isPortrait && event.logicalKey == LogicalKeyboardKey.pageDown) {
            _scrollBy(3);
          } else if (!isPortrait && event.logicalKey == LogicalKeyboardKey.pageUp) {
            _scrollBy(-3);
          } else if (event.logicalKey == LogicalKeyboardKey.home) {
            _animateTo(0);
          } else if (event.logicalKey == LogicalKeyboardKey.end && _scrollController.hasClients) {
            _animateTo(_scrollController.position.maxScrollExtent);
          }
        }
      },
      child: WillPopScope(
        onWillPop: () async {
          _handleEscKey();
          return false;
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF0B1120),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, viewport) {
                final padding = MediaQuery.of(context).padding;
                final safeVerticalPadding = padding.top + padding.bottom;
                final effectiveBaseHeight = _baseHeight - safeVerticalPadding;
                final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
                final canRenderOneToOne =
                    !isPortrait && viewport.maxWidth >= _baseWidth && viewport.maxHeight >= effectiveBaseHeight;

                Widget contentBuilder() {
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _calculateResponsiveCardSize();
                      });
                      return Consumer<AppState>(
                        builder: (context, appState, child) {
                          final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
                          
                          return Stack(
                            children: [
                              Column(
                                children: [
                                  Container(
                                    padding: EdgeInsets.only(top: isPortrait ? 282.0 : 32.0),
                                    child: Column(
                                      children: [
                                        if (_currentPresets.isNotEmpty && isPortrait) ...[
                                          _buildTakePictureButton(),
                                          const SizedBox(height: 16),
                                        ],

                                        Padding(
                                          padding: EdgeInsets.only(top: isPortrait ? 90.0 : 32.0),
                                          child: Text(
                                            'Select Theme',
                                            style: const TextStyle(
                                              fontSize: 40,
                                              fontWeight: FontWeight.w800,
                                              color: Colors.white,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  
                                  Expanded(
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        final double arrowTop = constraints.maxHeight / 2 - 22.0 - 10.0;
                                        final pageCount = _portraitPageCount();
                                        final bool showUpArrow = isPortrait && pageCount > 1 && _portraitPage > 0;
                                        final bool showDownArrow = isPortrait && pageCount > 1 && _portraitPage < pageCount - 1;
                                        final tileHeight = _portraitTileHeight();
                                        final rowGap = _getGap();
                                        final carouselHeight = tileHeight * 2 + rowGap;
                                        final carouselTop = (constraints.maxHeight - carouselHeight) / 2;
                                        const buttonSize = 44.0;
                                        const buttonGap = 8.0;
                                        final portraitButtonLeft = (constraints.maxWidth / 2 - buttonSize / 2)
                                            .clamp(0.0, math.max(0.0, constraints.maxWidth - buttonSize))
                                            .toDouble();
                                        const upButtonNudge = 6.0;
                                        final portraitUpButtonTop = (carouselTop - buttonSize - buttonGap - upButtonNudge)
                                            .clamp(0.0, math.max(0.0, constraints.maxHeight - buttonSize))
                                            .toDouble();
                                        final portraitDownButtonTop = (carouselTop + carouselHeight + buttonGap)
                                            .clamp(0.0, math.max(0.0, constraints.maxHeight - buttonSize))
                                            .toDouble();
                                        return Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            _buildPresetsCarousel(),
                                            if (!isPortrait && _showLeftArrow)
                                              Positioned(
                                                left: 8,
                                                top: arrowTop,
                                                child: Transform.translate(
                                                  offset: const Offset(0, -10),
                                                  child: _buildArrowButton(_ArrowDirection.left, () => _scrollBy(-1)),
                                                ),
                                              ),
                                            if (!isPortrait && _showRightArrow)
                                              Positioned(
                                                right: 8,
                                                top: arrowTop,
                                                child: Transform.translate(
                                                  offset: const Offset(0, -10),
                                                  child: _buildArrowButton(_ArrowDirection.right, () => _scrollBy(1)),
                                                ),
                                              ),
                                            if (showUpArrow)
                                              Positioned(
                                                left: portraitButtonLeft,
                                                top: portraitUpButtonTop,
                                                child: _buildArrowButton(_ArrowDirection.up, () => _scrollPortraitPage(-1)),
                                              ),
                                            if (showDownArrow)
                                              Positioned(
                                                left: portraitButtonLeft,
                                                top: portraitDownButtonTop,
                                                child: _buildArrowButton(_ArrowDirection.down, () => _scrollPortraitPage(1)),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),

                                  if (_currentPresets.isNotEmpty && !isPortrait)
                                    Transform.translate(
                                      offset: const Offset(0, -65),
                                      child: _buildTakePictureButton(),
                                    ) else if (_currentPresets.isEmpty) ...[
                                    const SizedBox(height: 72),
                                  ],
                                ],
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                }

                if (isPortrait) {
                  return SizedBox(
                    width: viewport.maxWidth,
                    height: viewport.maxHeight - safeVerticalPadding,
                    child: contentBuilder(),
                  );
                }

                return SizedBox(
                  width: viewport.maxWidth,
                  height: viewport.maxHeight - safeVerticalPadding,
                  child: canRenderOneToOne
                      ? Align(
                          alignment: Alignment.topCenter,
                          child: SizedBox(
                            width: _baseWidth,
                            height: effectiveBaseHeight,
                            child: contentBuilder(),
                          ),
                        )
                      : FittedBox(
                          fit: BoxFit.contain,
                          alignment: Alignment.center,
                          child: SizedBox(
                            width: _baseWidth,
                            height: effectiveBaseHeight,
                            child: contentBuilder(),
                          ),
                        ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArrowButton(_ArrowDirection direction, VoidCallback onPressed) {
    return _HoverableArrowButton(
      direction: direction,
      onPressed: onPressed,
    );
  }

  Widget _buildEmptyState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'ðŸ“',
            style: TextStyle(
              fontSize: 80,
              color: Color(0xFF6B7280),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'No collections found.',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF9CA3AF),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Create some presets and assign them to collections first.',
            style: TextStyle(
              fontSize: 16,
              color: Color(0xFF6B7280),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFCC66FF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Go Back',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildPresetsCarousel() {
    if (_currentPresets.isEmpty) {
      return const Center(
        child: Text(
          'No presets in this collection',
          style: TextStyle(
            fontSize: 18,
            color: Color(0xFF6B7280),
          ),
        ),
      );
    }

    final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
    if (isPortrait) {
      final gap = _getGap();
      final groupWidth = _cardWidth * 3 + gap * 2;
      final pageCount = _portraitPageCount();
      final tileHeight = _portraitTileHeight();

      return Center(
        child: Listener(
          onPointerSignal: (signal) {
            if (signal is PointerScrollEvent) {
              _bumpPortraitScrollbar();
              if (_portraitWheelTimer?.isActive ?? false) return;

              final dy = signal.scrollDelta.dy;
              if (dy.abs() < 0.5) return;

              _scrollPortraitPage(dy > 0 ? 1 : -1);
              _portraitWheelTimer = Timer(const Duration(milliseconds: 120), () {});
            }
          },
          child: SizedBox(
            width: groupWidth,
            height: tileHeight * 2 + gap,
            child: RawScrollbar(
              controller: _portraitPageController,
              thumbVisibility: _showPortraitScrollbar,
              thickness: 3,
              radius: const Radius.circular(8),
              fadeDuration: const Duration(milliseconds: 200),
              timeToFade: const Duration(milliseconds: 650),
              thumbColor: const Color(0x66FFFFFF),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) {
                  _bumpPortraitScrollbar();
                  _portraitDragTriggered = false;
                  _portraitDragDy = 0.0;
                },
                onVerticalDragUpdate: (details) {
                  _bumpPortraitScrollbar();
                  if (_portraitDragTriggered) return;
                  _portraitDragDy += details.delta.dy;
                  if (_portraitDragDy.abs() >= 28.0) {
                    _portraitDragTriggered = true;
                    _scrollPortraitPage(_portraitDragDy > 0 ? -1 : 1);
                  }
                },
                onVerticalDragEnd: (details) {
                  _bumpPortraitScrollbar();
                  if (_portraitDragTriggered) return;
                  final vy = details.primaryVelocity ?? details.velocity.pixelsPerSecond.dy;
                  if (vy.abs() < 140) return;
                  _scrollPortraitPage(vy > 0 ? -1 : 1);
                },
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n is ScrollStartNotification || n is ScrollUpdateNotification) {
                      _bumpPortraitScrollbar();
                    }
                    return false;
                  },
                  child: PageView.builder(
                    controller: _portraitPageController,
                    scrollDirection: Axis.vertical,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: pageCount,
                    onPageChanged: (idx) => _setPortraitPage(idx),
                    itemBuilder: (context, pageIdx) {
                      final start = pageIdx * 6;
                      final end = math.min(start + 6, _currentPresets.length);

                    Widget slot(int absoluteIndex) {
                      if (absoluteIndex < end) {
                        return _buildPresetCard(_currentPresets[absoluteIndex], absoluteIndex);
                      }
                      return SizedBox(width: _cardWidth, height: tileHeight);
                    }

                    Widget row(int rowStart) {
                      final a = rowStart;
                      final b = rowStart + 1;
                      final c = rowStart + 2;
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          slot(a),
                          SizedBox(width: gap),
                          slot(b),
                          SizedBox(width: gap),
                          slot(c),
                        ],
                      );
                    }

                    return Align(
                      alignment: Alignment.topCenter,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          row(start),
                          SizedBox(height: gap),
                          row(start + 3),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          ),
        ),
      );
    }

    return Center(
      child: Listener(
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent && _scrollController.hasClients) {
            final dx = signal.scrollDelta.dx;
            final dy = signal.scrollDelta.dy;
            final primary = dx.abs() > 0.0 ? dx : dy;
            final target = (_scrollController.offset + primary * -1.0)
                .clamp(0.0, _scrollController.position.maxScrollExtent);
            _animateTo(target.toDouble());
          }
        },
        child: SizedBox(
        height: _cardHeight + (MediaQuery.of(context).orientation == Orientation.landscape ? 60 : 100),
        child: ListView.builder(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: math.max(
              MediaQuery.of(context).orientation == Orientation.portrait ? sidePaddingPortrait : 0.0,
              (MediaQuery.of(context).size.width - _cardWidth) / 2,
            ),
          ),
          itemCount: _currentPresets.length,
          itemBuilder: (context, index) {
            return Padding(
              padding: EdgeInsets.only(
                right: index < _currentPresets.length - 1 ? _getGap() : 0,
              ),
              child: _buildPresetCard(_currentPresets[index], index),
            );
          },
        ),
        ),
      ),
    );
  }


  Widget _buildPresetCard(Preset preset, int index) {
    final isSelected = index == _selectedIndex;

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: _cardWidth,
              height: _cardHeight,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected ? const Color(0xFFCC66FF) : const Color(0xFF374151),
                  width: isSelected ? 2 : 1,
                ),
                boxShadow: isSelected
                    ? [
                        const BoxShadow(
                          color: Color(0x66CC66FF),
                          blurRadius: 24,
                          spreadRadius: 2,
                          offset: Offset(0, 6),
                        ),
                      ]
                    : [
                        const BoxShadow(
                          color: Color(0x1A000000),
                          blurRadius: 24,
                          offset: Offset(0, 6),
                        ),
                      ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ThumbnailCacheService.instance.isSupportedImageSource(preset.generatedImageUrls)
                    ? Image(
                        image: (() {
                          final dpr = MediaQuery.of(context).devicePixelRatio;
                          return ThumbnailCacheService.instance.providerForResized(
                            preset.generatedImageUrls,
                            cacheWidth: (_cardWidth * dpr).round(),
                          );
                        })(),
                        fit: BoxFit.contain,
                        alignment: Alignment.center,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildPlaceholderImage();
                        },
                      )
                    : _buildPlaceholderImage(),
              ),
            ),
            const SizedBox(height: 4),

            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                preset.title.isNotEmpty ? preset.title : preset.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

          if (_hasPostDeliveryPreset)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                _labelForPreset(preset),
                style: const TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholderImage() {
    return Container(
      color: const Color(0xFF1F2937),
      child: const Center(
        child: Icon(
          Icons.photo_camera,
          size: 100,
          color: Color(0xFF6B7280),
        ),
      ),
    );
  }

  Widget _buildTakePictureButton() {
    final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
    final horizontalPadding = isPortrait ? 64.0 : 48.0;
    final verticalPadding = isPortrait ? 20.0 : 16.0;
    final minWidth = isPortrait ? 280.0 : 220.0;
    final minHeight = isPortrait ? 56.0 : 48.0;
    final fontSize = isPortrait ? 18.0 : 16.0;
    
    return Center(
      child: ElevatedButton(
        onPressed: () => _onTakePicture(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFCC66FF),
          foregroundColor: Colors.white,
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: verticalPadding),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          minimumSize: Size(minWidth, minHeight),
        ),
        child: Text(
          'Take Picture',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

enum _ArrowDirection { left, right, up, down }

class _HoverableArrowButton extends StatefulWidget {
  final _ArrowDirection direction;
  final VoidCallback onPressed;

  const _HoverableArrowButton({
    required this.direction,
    required this.onPressed,
  });

  @override
  State<_HoverableArrowButton> createState() => _HoverableArrowButtonState();
}

class _HoverableArrowButtonState extends State<_HoverableArrowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final double angle = switch (widget.direction) {
      _ArrowDirection.left => math.pi / 2,
      _ArrowDirection.right => -math.pi / 2,
      _ArrowDirection.up => 0.0,
      _ArrowDirection.down => 0.0,
    };
    final bool isUpward = widget.direction == _ArrowDirection.up;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
          decoration: BoxDecoration(
            color: _isHovered 
                ? Colors.black.withOpacity(0.15)
                : Colors.black.withOpacity(0.05),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1),
          ),
          child: Center(
            child: Transform.rotate(
              angle: angle,
              alignment: Alignment.center,
              child: SizedBox(
                width: 18,
                height: 18,
                child: Center(
                  child: ChevronWidget(
                    isUpward: isUpward,
                    color: Color(0xFF7C3AED),
                    size: 18,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}



