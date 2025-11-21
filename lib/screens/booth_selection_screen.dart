import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../services/preset_service.dart';
import '../services/session_service.dart';
import '../done_button_app.dart';
import '../providers/app_state.dart';
import '../models/preset.dart';
import '../models/collection.dart';
import '../widgets/chevron_widget.dart';
import '../services/thumbnail_cache_service.dart';

/// Booth Selection Screen - Horizontal carousel matching legacy app exactly
class BoothSelectionScreen extends StatefulWidget {
  const BoothSelectionScreen({super.key, this.collectionFilter});

  final String? collectionFilter; // null means show all

  @override
  State<BoothSelectionScreen> createState() => _BoothSelectionScreenState();
}

class _BoothSelectionScreenState extends State<BoothSelectionScreen>
    with SingleTickerProviderStateMixin {
  // Design canvas for 1:1 rendering
  static const double _baseWidth = 1920;
  static const double _baseHeight = 1080;
  List<Preset> _currentPresets = [];
  int _selectedIndex = 0;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  Timer? _snapTimer;
  Timer? _coalesceTimer;
  Timer? _workerPollTimer;
  Timer? _donePollTimer;
  bool _minimizing = false;
  
  // Square cards with responsive sizing (maintains 3-card layout)
  static const double baseWidth = 600.0;
  static const double baseHeight = 600.0;
  static const double aspectRatio = 1.0; // Square aspect ratio
  static const double minWidth = 550.0;
  static const double maxWidth = 700.0;
  static const double gap = 80.0;
  static const double gapLandscape = 30.0; // Reduced gap for landscape
  static const double gapPortrait = 150.0; // Large gap for portrait to ensure only one card visible
  static const double wheelSpeed = 0.28; // gentler scroll feel
  static const int minDuration = 300;
  static const int maxDuration = 800;
  static const int snapDuration = 300; // Longer duration for smoother motion
  static const int snapDurationLandscape = 300; // Faster snap for landscape
  static const int snapIdle = 150; // Shorter idle for quicker response
  static const double snapHysteresis = 0.30;

  bool _isUserScrolling = false;
  
  /// Get gap between cards based on orientation
  double _getGap() {
    if (!mounted) return gap;
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.landscape) {
      return gapLandscape;
    } else {
      return gapPortrait; // Portrait uses minimal gap
    }
  }
  bool _showLeftArrow = false;
  bool _showRightArrow = false;
  
  // Responsive card dimensions (calculated from screen width)
  double _cardWidth = baseWidth;
  double _cardHeight = baseHeight;
  bool _hasPostDeliveryPreset = false;

  @override
  void initState() {
    super.initState();
    // Verbose log
    // ignore: avoid_print
    print('BoothSelectionScreen:init');
    _selectedIndex = 0;
    _scrollController.addListener(_onScroll);
    
    // Request focus for ESC key handling - exactly like legacy app
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _updateArrows();
      _calculateResponsiveCardSize();
      _setFullscreenFrameless();
      // ignore: avoid_print
      print('BoothSelectionScreen:postFrame ready');
      _initPresetsFromFilter();
    });
  }
  
  Future<void> _setFullscreenFrameless() async {
    if (Platform.isWindows) {
      await windowManager.setFullScreen(true);
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }
  }
  
  /// Calculate responsive card size with dynamic centering for 1-3 cards
  void _calculateResponsiveCardSize() {
    if (!mounted) return;
    
    final screenWidth = MediaQuery.of(context).size.width;
    final orientation = MediaQuery.of(context).orientation;
    
    if (orientation == Orientation.portrait) {
      // Portrait mode: single large card that fills most of the screen width
      // Use 88% of screen width to ensure only one card is visible at a time
      final screenHeight = MediaQuery.of(context).size.height;
      final maxCardByWidth = screenWidth * 0.88;
      final maxCardByHeight = screenHeight * 0.60; // Use up to 60% of height
      // Use the smaller of the two to maintain square aspect ratio
      _cardWidth = math.min(maxCardByWidth, maxCardByHeight);
      _cardHeight = _cardWidth; // Square cards
    } else {
      // Landscape mode: 3 cards
      const maxVisibleCols = 3;
      final currentGap = _getGap();
      final totalGaps = (maxVisibleCols - 1) * currentGap; // 2 gaps
      
      final availableWidth = screenWidth - totalGaps;
      final calculatedWidth = availableWidth / maxVisibleCols;
      
      // Force larger cards to ensure only 3 fit - use calculated width but with higher minimum
      _cardWidth = math.max(minWidth, calculatedWidth);
      _cardHeight = _cardWidth; // Square cards (aspect ratio = 1.0)
    }
    
    setState(() {}); // Trigger rebuild with new dimensions
  }

  String _labelForPreset(Preset preset) {
    // Prefer explicit presetType if available on the model (name or url fallback)
    final type = (preset.postProcessingUrl.toLowerCase().contains('post-delivery'))
        ? 'post-delivery'
        : 'live';
    return type;
  }

  void _initPresetsFromFilter() {
    final appState = Provider.of<AppState>(context, listen: false);
    // Ignore data source: combine live and post-delivery presets
    final presetService = PresetService();
    final allPresets = <Preset>[
      ...presetService.localPresets,
      ...presetService.localPostDeliveryPresets,
    ];
    final String? filter = widget.collectionFilter;
    List<Preset> list;
    if (filter == null) {
      list = allPresets;
    } else {
      list = allPresets.where((p) => p.collection == filter).toList();
    }

    // Add No Effects if enabled
    if (appState.noEffectsEnabled) {
      final noEffectsPreset = _createNoEffectsPreset();
      list.insert(0, noEffectsPreset);
    }

    setState(() {
      _currentPresets = list;
      _selectedIndex = _currentPresets.isNotEmpty ? 0 : -1;
      _hasPostDeliveryPreset = list.any(
        (p) => p.postProcessingUrl.toLowerCase().contains('post-delivery'),
      );
    });

    // After the list is built and ListView attached to the controller, refresh arrows
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateArrows();
    });
  }

  @override
  void dispose() {
    _snapTimer?.cancel();
    _coalesceTimer?.cancel();
    _workerPollTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    _updateArrows();
    
    // Update selected index based on centered card
    final orientation = MediaQuery.of(context).orientation;
    if (_scrollController.hasClients && _currentPresets.isNotEmpty) {
      final vpw = MediaQuery.of(context).size.width;
      final step = _cardWidth + _getGap();
      
      final itemCount = _currentPresets.length;
      if (orientation == Orientation.portrait) {
        // Portrait: card centered on screen
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
        // Landscape: card below the title (centered card)
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
    
    // Start coalesce timer for snap
    _isUserScrolling = true;
    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(const Duration(milliseconds: snapIdle), () {
      _isUserScrolling = false;
      _snapToCard(hysteresis: true);
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
    final step = _cardWidth + _getGap();
    
    final itemCount = _currentPresets.length;
    if (orientation == Orientation.portrait) {
      // Portrait: snap to center of each card
      final center = _scrollController.offset + vpw / 2.0;
      final horizontalPadding = (vpw - _cardWidth) / 2.0;
      final cardCenterOffset = horizontalPadding + _cardWidth / 2.0;
      final relativeOffset = center - cardCenterOffset;
      final idxFloat = relativeOffset / step;
      final clampedIdx = math.max(0, math.min(itemCount - 1, idxFloat.round()));
      
      // Update selected index to the centered card
      if (clampedIdx != _selectedIndex) {
        setState(() {
          _selectedIndex = clampedIdx;
        });
      }
      
      // Snap to the center of the selected card
      final target = horizontalPadding + clampedIdx * step + _cardWidth / 2.0 - vpw / 2.0;
      final clampedTarget = math.max(
        0.0,
        math.min(_scrollController.position.maxScrollExtent, target),
      );
      
      _animateTo(clampedTarget, duration: snapDurationLandscape);
    } else {
      // Landscape: use consistent centering logic
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

  void _animateTo(double target, {int? duration}) {
    if (!_scrollController.hasClients) return;
    
    final start = _scrollController.offset;
    final distance = (target - start).abs();
    
    // Skip if already very close to target
    if (distance < 0.5) return;
    
    final actualDuration = duration ?? _calculateDuration(start, target);
    
    // Use very smooth, fluid curve for both orientations (watery smooth)
    final curve = Curves.easeOutQuart;
    
    _scrollController.animateTo(
      target,
      duration: Duration(milliseconds: actualDuration),
      curve: curve,
    );
  }

  int _calculateDuration(double start, double target) {
    final dist = (target - start).abs();
    // Distance-based duration with smoother scaling
    final normalized = math.min(1.0, dist / 1200.0);
    // Use a gentler power curve for smoother duration transitions
    final eased = math.pow(normalized, 0.5) as double; // Smoother duration curve
    final duration = (minDuration + (maxDuration - minDuration) * eased).toInt();
    return math.max(minDuration, math.min(maxDuration, duration));
  }

  void _scrollBy(int steps) {
    if (!_scrollController.hasClients) return;
    
    final step = baseWidth + _getGap();
    final target = math.max(
      0.0,
      math.min(
        _scrollController.position.maxScrollExtent,
        _scrollController.offset + steps * step,
      ),
    );
    
    _animateTo(target);
    
    // Start coalesce for snap after arrow click
    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(const Duration(milliseconds: snapIdle), () {
      _snapToCard(hysteresis: true);
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
      // Leave empty so UI uses the same placeholder as default
      generatedImageUrls: '',
      collection: 'No Effects',
      thumbnailPath: '',
      createdAt: DateTime.now().millisecondsSinceEpoch.toString(),
      isNoEffects: true,
    );
  }

  void _onTakePicture(BuildContext context) async {
    final appState = Provider.of<AppState>(context, listen: false);
    if (_currentPresets.isEmpty) {
      return;
    }

    // TODO: Implement photo booth logic (minimize app, wait for files)
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Photo booth mode activated! Waiting for images...'),
        backgroundColor: Color(0xFFCC66FF),
        duration: Duration(seconds: 2),
      ),
    );

    appState.setStayMinimizedDuringCapture(true);

    // Persist selected preset for worker mode (second instance)
    final preset = _currentPresets[_selectedIndex];
    await SessionService.saveSelectedPreset(preset, presetPassword: appState.presetPassword);
    
    // Clear any previous completion signals
    await SessionService.clearWorkerDone();
    await SessionService.clearDonePressed();

    if (Platform.isWindows) {
      // Seamless minimize: fade out, exit fullscreen if needed, then minimize
      if (_minimizing) return;
      _minimizing = true;
      try {
        await windowManager.setOpacity(0.0);
        await Future.delayed(const Duration(milliseconds: 16));
        final isFS = await windowManager.isFullScreen();
        if (isFS) {
          await windowManager.setFullScreen(false);
          await Future.delayed(const Duration(milliseconds: 16));
        }
        await windowManager.minimize();
      } catch (_) {
        // ignore
      } finally {
        // Keep opacity at 0; restore flow will bring it back to 1.0
        _minimizing = false;
      }
    }
    
    // Start polling for worker completion signal
    _startWorkerCompletionPolling(appState);
  }
  
  void _startWorkerCompletionPolling(AppState appState) {
    _workerPollTimer?.cancel();
    _workerPollTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
      final isDone = await SessionService.checkWorkerDone();
      if (isDone) {
        timer.cancel();
        await SessionService.clearWorkerDone();
        if (mounted) {
          // Stop showing the Done overlay; rely solely on server-driven completion
          _startDonePressedPolling(appState);
        }
      }
    });
  }

  // Removed Done overlay launcher; server 'session_end' will trigger completion

  bool _restoring = false;
  Future<void> _restoreSeamless(AppState appState) async {
    if (_restoring) return;
    _restoring = true;
    try {
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setOpacity(0.0);
      await windowManager.restore();
      await windowManager.show();
      await Future.delayed(const Duration(milliseconds: 20));
      await windowManager.focus();
      await Future.delayed(const Duration(milliseconds: 20));
      await windowManager.setFullScreen(true);
      await Future.delayed(const Duration(milliseconds: 60));
      await windowManager.setOpacity(1.0);
    } catch (_) {} finally {
      await windowManager.setAlwaysOnTop(false);
      appState.setStayMinimizedDuringCapture(false);
      _restoring = false;
    }
  }

  void _startDonePressedPolling(AppState appState) {
    _donePollTimer?.cancel();
    _donePollTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) async {
      final pressed = await SessionService.checkDonePressed();
      if (pressed) {
        timer.cancel();
        await SessionService.clearDonePressed();
        if (mounted && Platform.isWindows) {
          await _restoreSeamless(appState);
        }
      }
    });
  }

  void _handleEscKey() async {
    // Consistent fullscreen policy: just navigate back without toggling fullscreen
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
        // Handle ESC key exactly like legacy app
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            _handleEscKey();
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            _scrollBy(1);
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            _scrollBy(-1);
          } else if (event.logicalKey == LogicalKeyboardKey.pageDown) {
            _scrollBy(3);
          } else if (event.logicalKey == LogicalKeyboardKey.pageUp) {
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
                  // Original body, now built inside base-sized box
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
                                    padding: EdgeInsets.only(top: isPortrait ? 282.0 : 32.0), // 32 + 250 = 282 for portrait
                                    child: Column(
                                      children: [
                                        // Take Picture button at top in portrait mode
                                        if (_currentPresets.isNotEmpty && isPortrait) ...[
                                          _buildTakePictureButton(),
                                          const SizedBox(height: 16),
                                        ],
                                        // Title below button in portrait, at top in landscape
                                        Padding(
                                          padding: EdgeInsets.only(top: isPortrait ? 90.0 : 32.0), // 340 - 250 = 90 for portrait, 64 - 32 = 32 for landscape
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
                                        // Center vertically then shift upwards by 10px
                                        final double arrowTop = constraints.maxHeight / 2 - 22.0 - 10.0; // 22 = half of bubble (44/2)
                                        return Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            _buildPresetsCarousel(),
                                            if (_showLeftArrow)
                                              Positioned(
                                                left: 8,
                                                top: arrowTop,
                                                child: Transform.translate(
                                                  offset: const Offset(0, -10),
                                                  child: _buildArrowButton(true, () => _scrollBy(-1)),
                                                ),
                                              ),
                                            if (_showRightArrow)
                                              Positioned(
                                                right: 8,
                                                top: arrowTop,
                                                child: Transform.translate(
                                                  offset: const Offset(0, -10),
                                                  child: _buildArrowButton(false, () => _scrollBy(1)),
                                                ),
                                              ),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                  
                                  // Take Picture button at bottom in landscape mode
                                  if (_currentPresets.isNotEmpty && !isPortrait)
                                    Transform.translate(
                                      offset: const Offset(0, -65), // Move button up by 65px
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

                // Portrait: render directly without fixed canvas
                if (isPortrait) {
                  return SizedBox(
                    width: viewport.maxWidth,
                    height: viewport.maxHeight - safeVerticalPadding,
                    child: contentBuilder(),
                  );
                }

                // Landscape: use fixed canvas approach
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

  Widget _buildArrowButton(bool isLeft, VoidCallback onPressed) {
    return _HoverableArrowButton(
      isLeft: isLeft,
      onPressed: onPressed,
    );
  }

  Widget _buildEmptyState() {
    // Ensure focus for ESC key even in empty state
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '📁',
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

  // Collection carousel removed per requirements

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

    return Center(
      child: Listener(
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent && _scrollController.hasClients) {
            final dx = signal.scrollDelta.dx;
            final dy = signal.scrollDelta.dy;
            final primary = dx.abs() > 0.0 ? dx : dy; // prefer horizontal, fallback to vertical
            final target = (_scrollController.offset + primary * -1.0)
                .clamp(0.0, _scrollController.position.maxScrollExtent);
            _animateTo(target.toDouble());
          }
        },
        child: SizedBox(
        height: _cardHeight + (MediaQuery.of(context).orientation == Orientation.landscape ? 60 : 100), // Less space in landscape
        child: ListView.builder(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(), // Disable bouncing for smoother snapping
          padding: EdgeInsets.symmetric(
            horizontal: (MediaQuery.of(context).size.width - _cardWidth) / 2,
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

  // Collection card removed per requirements

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
            // Preset card - exact from legacy
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
                child: preset.generatedImageUrls.isNotEmpty
                    ? Image(
                        image: (() {
                          final dpr = MediaQuery.of(context).devicePixelRatio;
                          // Decode to the card's logical width at device scale; let BoxFit handle aspect
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
                        // No loadingBuilder; MemoryImage will appear instantly if cached
                      )
                    : _buildPlaceholderImage(),
              ),
            ),
            const SizedBox(height: 4),
            
            // Preset title - exact from legacy
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
          // Preset type label (live / post-delivery)
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
        child: Text(
          '📷',
          style: TextStyle(
            fontSize: 100,
            color: Color(0xFF6B7280),
          ),
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

class _HoverableArrowButton extends StatefulWidget {
  final bool isLeft;
  final VoidCallback onPressed;

  const _HoverableArrowButton({
    required this.isLeft,
    required this.onPressed,
  });

  @override
  State<_HoverableArrowButton> createState() => _HoverableArrowButtonState();
}

class _HoverableArrowButtonState extends State<_HoverableArrowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
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
              angle: widget.isLeft ? math.pi / 2 : -math.pi / 2,
              alignment: Alignment.center,
              child: const SizedBox(
                width: 18,
                height: 18,
                child: Center(
                  child: ChevronWidget(
                    isUpward: false,
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
