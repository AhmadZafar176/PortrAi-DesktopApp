import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
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

/// Booth Selection Screen - Horizontal carousel matching legacy app exactly
class BoothSelectionScreen extends StatefulWidget {
  const BoothSelectionScreen({super.key});

  @override
  State<BoothSelectionScreen> createState() => _BoothSelectionScreenState();
}

class _BoothSelectionScreenState extends State<BoothSelectionScreen>
    with SingleTickerProviderStateMixin {
  // Design canvas for 1:1 rendering
  static const double _baseWidth = 1920;
  static const double _baseHeight = 1080;
  Collection? _selectedCollection;
  List<Preset> _currentPresets = [];
  int _selectedIndex = 0;
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  Timer? _snapTimer;
  Timer? _coalesceTimer;
  Timer? _workerPollTimer;
  
  // Square cards with responsive sizing (maintains 3-card layout)
  static const double baseWidth = 600.0;
  static const double baseHeight = 600.0;
  static const double aspectRatio = 1.0; // Square aspect ratio
  static const double minWidth = 550.0;
  static const double maxWidth = 700.0;
  static const double gap = 80.0;
  static const double wheelSpeed = 0.28; // gentler scroll feel
  static const int minDuration = 240;
  static const int maxDuration = 1200;
  static const int snapDuration = 560;
  static const int snapIdle = 240;
  static const double snapHysteresis = 0.30;

  bool _isUserScrolling = false;
  bool _showLeftArrow = false;
  bool _showRightArrow = false;
  
  // Responsive card dimensions (calculated from screen width)
  double _cardWidth = baseWidth;
  double _cardHeight = baseHeight;

  @override
  void initState() {
    super.initState();
    _selectedIndex = 0;
    _scrollController.addListener(_onScroll);
    
    // Request focus for ESC key handling - exactly like legacy app
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _updateArrows();
      _calculateResponsiveCardSize();
      _setFullscreenFrameless();
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
      // Portrait mode: single large card
      _cardWidth = math.min(screenWidth * 0.8, 400.0); // 80% of screen width, max 400px
      _cardHeight = _cardWidth; // Square cards
    } else {
      // Landscape mode: 3 cards
      const maxVisibleCols = 3;
      const totalGaps = (maxVisibleCols - 1) * gap; // 2 gaps = 160px
      
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
    
    final canScroll = _scrollController.position.maxScrollExtent > 0;
    final atMin = _scrollController.offset <= _scrollController.position.minScrollExtent + 1;
    final atMax = _scrollController.offset >= _scrollController.position.maxScrollExtent - 1;
    
    setState(() {
      _showLeftArrow = canScroll && !atMin;
      _showRightArrow = canScroll && !atMax;
    });
  }

  void _snapToCard({bool hysteresis = false}) {
    if (!_scrollController.hasClients) return;
    
    final step = _cardWidth + gap;
    final vpw = MediaQuery.of(context).size.width;
    final center = _scrollController.offset + vpw / 2.0;
    final idxFloat = (center - (_cardWidth / 2.0)) / step;
    final idxFloor = idxFloat.floor();
    final frac = idxFloat - idxFloor;
    
    int idx;
    if (hysteresis) {
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
    
    final itemCount = _selectedCollection == null
        ? Provider.of<AppState>(context, listen: false).collections.length
        : _currentPresets.length;
    
    idx = math.max(0, math.min(itemCount - 1, idx));
    
    final target = (idx * step - (vpw / 2.0 - baseWidth / 2.0)).toDouble();
    final clampedTarget = math.max(
      0.0,
      math.min(_scrollController.position.maxScrollExtent, target),
    );
    
    _animateTo(clampedTarget, duration: snapDuration);
  }

  void _animateTo(double target, {int? duration}) {
    if (!_scrollController.hasClients) return;
    
    final start = _scrollController.offset;
    if ((start - target).abs() < 0.5) return;
    
    final actualDuration = duration ?? _calculateDuration(start, target);
    
    // Use a smoother natural easing (easeOutCubic-like)
    _scrollController.animateTo(
      target,
      duration: Duration(milliseconds: actualDuration),
      curve: const Cubic(0.22, 0.9, 0.1, 1.0),
    );
  }

  int _calculateDuration(double start, double target) {
    final dist = (target - start).abs();
    // Distance-based easing with diminishing returns for long scrolls
    final normalized = math.min(1.0, dist / 1200.0);
    final eased = math.pow(normalized, 0.6) as double; // quicker settle at the end
    final duration = (minDuration + (maxDuration - minDuration) * eased).toInt();
    return math.max(minDuration, math.min(maxDuration, duration));
  }

  void _scrollBy(int steps) {
    if (!_scrollController.hasClients) return;
    
    final step = baseWidth + gap;
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

  void _selectCollection(Collection collection, AppState appState) {
    setState(() {
      _selectedCollection = collection;
      // Get presets for this collection across ALL preset types
      final presetService = PresetService();
      _currentPresets = [
        ...presetService.localPresets.where((p) => p.collection == collection.name),
        ...presetService.localPostDeliveryPresets.where((p) => p.collection == collection.name),
      ];
      
      // Add No Effects preset if enabled
      if (appState.noEffectsEnabled) {
        final noEffectsPreset = _createNoEffectsPreset();
        _currentPresets.insert(0, noEffectsPreset);
      }
      
      _selectedIndex = _currentPresets.isNotEmpty ? 0 : -1;
    });
    
    // Reset scroll position and maintain focus for ESC key
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
      _focusNode.requestFocus();
      _updateArrows();
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
      generatedImageUrls: 'https://firebasestorage.googleapis.com/v0/b/ai-booth-edda3.firebasestorage.app/o/generations%2F1yOQlRrxwrOvv6L5urQM4pTTTFV2%2Finputs%2Fsecond%2F1760111631964_1760111619628_fk0nq2_0_WhatsApp%20Image%202025-10-10%20at%208.51.04%20PM.jpeg?alt=media&token=fd6cc553-5084-4684-9ba3-3ec036f9b384',
      collection: 'No Effects',
      thumbnailPath: '',
      createdAt: DateTime.now().millisecondsSinceEpoch.toString(),
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
    SessionService.saveSelectedPreset(preset, presetPassword: appState.presetPassword);
    
    // Clear any previous completion signal
    await SessionService.clearWorkerDone();

    if (Platform.isWindows) {
      // Exit fullscreen first; some Windows shells won't minimize a fullscreen window
      try {
        await windowManager.setFullScreen(false);
        await Future.delayed(const Duration(milliseconds: 50));
      } catch (_) {}
      await windowManager.minimize();
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
          await _launchDoneButtonApp();
          _startDonePressedPolling(appState);
        }
      }
    });
  }

  Future<void> _launchDoneButtonApp() async {
    try {
      final exe = Platform.resolvedExecutable; // current executable
      // Spawn a new process with --done-button so main.dart routes to DoneButtonApp
      await Process.start(exe, ['--done-button'], mode: ProcessStartMode.detached);
    } catch (e) {
      // ignore: avoid_print
      print('Failed to launch Done button app: $e');
    }
  }

  void _startDonePressedPolling(AppState appState) {
    _workerPollTimer?.cancel();
    _workerPollTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) async {
      final pressed = await SessionService.checkDonePressed();
      if (pressed) {
        timer.cancel();
        await SessionService.clearDonePressed();
        if (mounted && Platform.isWindows) {
          await windowManager.restore();
          await windowManager.show();
          await windowManager.focus();
          await windowManager.setFullScreen(true);
          appState.setStayMinimizedDuringCapture(false);
        }
      }
    });
  }

  void _handleEscKey() async {
    // Consistent fullscreen policy: just navigate back without toggling fullscreen
    Navigator.of(context).pop();
  }

  void _onBack() {
    if (_selectedCollection != null) {
      setState(() {
        _selectedCollection = null;
        _currentPresets = [];
        _selectedIndex = 0;
      });
      
      // Reset scroll position and refocus
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
        _focusNode.requestFocus();
        _updateArrows();
      });
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: (KeyEvent event) {
        // Handle ESC key exactly like legacy app
        if (event is KeyDownEvent && 
            event.logicalKey == LogicalKeyboardKey.escape) {
          _handleEscKey();
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
                final canRenderOneToOne =
                    viewport.maxWidth >= _baseWidth && viewport.maxHeight >= effectiveBaseHeight;

                Widget contentBuilder() {
                  // Original body, now built inside base-sized box
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _calculateResponsiveCardSize();
                      });
                      return Consumer<AppState>(
                        builder: (context, appState, child) {
                          final presetService = PresetService();
                          final allPresets = [
                            ...presetService.localPresets,
                            ...presetService.localPostDeliveryPresets,
                          ];
                          final collectionsWithPresets = appState.collections.where((collection) {
                            final presetCount = allPresets
                                .where((preset) => preset.collection == collection.name)
                                .length;
                            return presetCount > 0;
                          }).toList();

                          if (collectionsWithPresets.isEmpty) {
                            return _buildEmptyState();
                          }

                          final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
                          
                          return Stack(
                            children: [
                              Column(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.only(top: 32),
                                    child: Text(
                                      _selectedCollection == null ? 'Select Collection' : 'Select Theme',
                                      style: const TextStyle(
                                        fontSize: 40,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  
                                  // Take Picture button at top in portrait mode
                                  if (_selectedCollection != null && isPortrait) ...[
                                    const SizedBox(height: 16),
                                    _buildTakePictureButton(),
                                    const SizedBox(height: 16),
                                  ],
                                  
                                  Expanded(
                                    child: Stack(
                                      children: [
                                        _selectedCollection == null
                                            ? _buildCollectionsCarousel(appState, collectionsWithPresets)
                                            : _buildPresetsCarousel(),
                                        if (_showLeftArrow)
                                          Positioned(
                                            left: 16,
                                            top: 0,
                                            bottom: 0,
                                            child: Center(
                                              child: _buildArrowButton(true, () => _scrollBy(-1)),
                                            ),
                                          ),
                                        if (_showRightArrow)
                                          Positioned(
                                            right: 16,
                                            top: 0,
                                            bottom: 0,
                                            child: Center(
                                              child: _buildArrowButton(false, () => _scrollBy(1)),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  
                                  // Take Picture button at bottom in landscape mode
                                  if (_selectedCollection != null && !isPortrait) ...[
                                    const SizedBox(height: 24),
                                    _buildTakePictureButton(),
                                    const SizedBox(height: 32),
                                  ] else if (_selectedCollection == null) ...[
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
                          alignment: Alignment.topCenter,
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

  Widget _buildCollectionsCarousel(AppState appState, List<Collection> collectionsWithPresets) {
    return Center(
      child: SizedBox(
        height: _cardHeight + 100, // Extra space for labels
        child: ListView.builder(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: (MediaQuery.of(context).size.width - _cardWidth) / 2,
          ),
          itemCount: collectionsWithPresets.length,
          itemBuilder: (context, index) {
            return Padding(
              padding: EdgeInsets.only(
                right: index < collectionsWithPresets.length - 1 ? gap : 0,
              ),
              child: _buildCollectionCard(collectionsWithPresets[index], index, appState),
            );
          },
        ),
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

    return Center(
      child: SizedBox(
        height: _cardHeight + 100, // Extra space for labels
        child: ListView.builder(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: (MediaQuery.of(context).size.width - _cardWidth) / 2,
          ),
          itemCount: _currentPresets.length,
          itemBuilder: (context, index) {
            return Padding(
              padding: EdgeInsets.only(
                right: index < _currentPresets.length - 1 ? gap : 0,
              ),
              child: _buildPresetCard(_currentPresets[index], index),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCollectionCard(Collection collection, int index, AppState appState) {
    // Count presets across ALL types
    final presetService = PresetService();
    final presetCount = [
      ...presetService.localPresets,
      ...presetService.localPostDeliveryPresets,
    ].where((p) => p.collection == collection.name).length;

    return GestureDetector(
      onTap: () => _selectCollection(collection, appState),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Collection card with gradient - exact from legacy
            Container(
              width: _cardWidth,
              height: _cardHeight,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFFCC66FF), Color(0xFF9333EA)],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF374151)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x1A000000),
                    blurRadius: 24,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  collection.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(height: 4),
            
            // Collection name label - exact from legacy
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                collection.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 2),
            
            // Preset count - exact from legacy
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                '$presetCount preset${presetCount != 1 ? 's' : ''}',
                style: const TextStyle(
                  color: Color(0xFFE5E7EB),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
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
                    ? Image.network(
                        preset.generatedImageUrls,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildPlaceholderImage();
                        },
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return _buildPlaceholderImage();
                        },
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
    return Center(
      child: ElevatedButton(
        onPressed: () => _onTakePicture(context),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFCC66FF),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          minimumSize: const Size(220, 48),
        ),
        child: const Text(
          'Take Picture',
          style: TextStyle(
            fontSize: 16,
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
                ? const Color(0xFF7C3AED).withOpacity(0.2) 
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Transform.rotate(
              angle: widget.isLeft ? math.pi / 2 : -math.pi / 2,
                          child: const ChevronWidget(
                isUpward: false,
                color: Color(0xFF7C3AED),
                            size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
