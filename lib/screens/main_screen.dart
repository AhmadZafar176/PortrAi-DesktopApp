import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
import '../services/log_service.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import '../providers/app_state.dart';
import '../widgets/user_profile_widget.dart';
import '../widgets/chevron_widget.dart';
import '../services/preset_service.dart';
import '../models/preset.dart';
import '../services/thumbnail_cache_service.dart';
import '../models/collection.dart';
import 'booth_selection_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WindowListener {

  static const double _baseWidth = 1920;
  static const double _baseHeight = 1080;
  final FocusNode _escFocusNode = FocusNode();
  bool _noEffectsEnabled = false;
  String? _selectedCollectionFilter;
  String _lastDataSource = 'live';
  AppState? _listenedAppState;
  bool _handlingDataSourceChange = false;

  List<Preset>? _cachedFilteredPresets;
  String? _cachedCollectionFilter;
  List<Preset>? _cachedPresetsRef;

  List<DropdownMenuItem<String>>? _cachedCollectionItems;
  List<Collection>? _cachedCollectionsRef;

  final Map<String, TextEditingController> _titleControllers = {};
  String _lastPreloadKey = '';
  Timer? _preloadTimer;
  bool _isNavigating = false;
  final ScrollController _presetsScrollController = ScrollController();

  static const double _approxPresetCardExtent = 220.0;
  static const int _preloadOverscanItems = 8;
  static const int _maxPreloadUrlsPerBurst = 48;

  TextEditingController _titleControllerFor(Preset preset) {
    return _titleControllers.putIfAbsent(
      preset.presetId,
      () => TextEditingController(text: preset.title),
    );
  }

  void _debouncedPreloadThumbnailsForWindow(
    BuildContext context,
    List<Preset> presets, {
    required int startIndex,
    required int endIndex,
  }) {
    if (presets.isEmpty) return;
    final s = startIndex.clamp(0, presets.length);
    final e = endIndex.clamp(0, presets.length);
    if (e <= s) return;

    final cappedEnd = (s + _maxPreloadUrlsPerBurst).clamp(0, e);
    final urls = <String>[];
    for (var i = s; i < cappedEnd; i++) {
      final u = presets[i].generatedImageUrls;
      if (ThumbnailCacheService.instance.isNetworkImageUrl(u)) {
        urls.add(u);
      }
    }
    if (urls.isEmpty) return;

    final key = '${presets.length}|$s|$cappedEnd|${_selectedCollectionFilter ?? ''}|$_lastDataSource';
    if (key == _lastPreloadKey) return;
    _lastPreloadKey = key;

    _preloadTimer?.cancel();
    _preloadTimer = Timer(const Duration(milliseconds: 120), () {
      ThumbnailCacheService.instance.preloadUrls(urls, context: context);
    });
  }

  void _preloadThumbnailsAroundViewport(BuildContext context, List<Preset> presets) {
    if (!_presetsScrollController.hasClients) {
      _debouncedPreloadThumbnailsForWindow(
        context,
        presets,
        startIndex: 0,
        endIndex: min(presets.length, _maxPreloadUrlsPerBurst),
      );
      return;
    }

    final metrics = _presetsScrollController.position;
    final firstApprox = (metrics.pixels / _approxPresetCardExtent).floor();
    final visibleApprox = (metrics.viewportDimension / _approxPresetCardExtent).ceil();
    final start = max(0, firstApprox - _preloadOverscanItems);
    final end = min(presets.length, firstApprox + visibleApprox + _preloadOverscanItems);

    _debouncedPreloadThumbnailsForWindow(context, presets, startIndex: start, endIndex: end);
  }

  @override
  void initState() {
    super.initState();
    _enterFullscreenFrameless();
    windowManager.addListener(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final appState = Provider.of<AppState>(context, listen: false);
    if (identical(_listenedAppState, appState)) return;
    _listenedAppState?.removeListener(_onAppStateChanged);
    _listenedAppState = appState;
    _lastDataSource = appState.dataSource;
    appState.addListener(_onAppStateChanged);
  }

  void _onAppStateChanged() {
    final appState = _listenedAppState;
    if (appState == null) return;
    if (!mounted) return;
    if (_handlingDataSourceChange) return;
    if (_lastDataSource == appState.dataSource) return;

    _handlingDataSourceChange = true;
    setState(() {
      _lastDataSource = appState.dataSource;
      _selectedCollectionFilter = null;
    });
    _handlingDataSourceChange = false;
  }

  Future<void> _enterFullscreenFrameless() async {
    if (Platform.isWindows) {
      await windowManager.ensureInitialized();
      await windowManager.setFullScreen(true);
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.show();
      await windowManager.focus();
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _preloadTimer?.cancel();
    _presetsScrollController.dispose();
    _escFocusNode.dispose();
    for (final controller in _titleControllers.values) {
      controller.dispose();
    }
    _listenedAppState?.removeListener(_onAppStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      autofocus: true,
      focusNode: _escFocusNode,
      onKey: (event) async {
        if (event.isKeyPressed(LogicalKeyboardKey.escape)) {
          final shouldExit = await _confirmExitDialog();
          if (shouldExit) {
            if (Platform.isWindows) {
              await windowManager.close();
            } else {

              Navigator.of(context).maybePop();
            }
          }
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: const Color(0xFF0B1120),
        body: SafeArea(
          maintainBottomViewPadding: true,
          child: LayoutBuilder(
          builder: (context, viewport) {
            final padding = MediaQuery.of(context).padding;
            final safeVerticalPadding = padding.top + padding.bottom;
            final effectiveBaseHeight = _baseHeight - safeVerticalPadding;
            final isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
            final canRenderOneToOne = !isPortrait && viewport.maxWidth >= _baseWidth && viewport.maxHeight >= effectiveBaseHeight;

            if (isPortrait) {
              return SizedBox(
                width: viewport.maxWidth,
                height: viewport.maxHeight - safeVerticalPadding,
                child: Consumer<AppState>(
        builder: (context, appState, child) {

          return Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 0),
                child: Center(
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 1600),
                        child: Padding(
                                            padding: const EdgeInsets.fromLTRB(24.0, 12.0, 24.0, 24.0),
                      child: Column(
                        children: [
                          Column(
                            children: [
                              const Text(
                                'Photobooth Setup',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Easily configure and manage your photobooth themes.',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFFCCCCCC),
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              _buildRealtimeIndicator(appState),
                            ],
                          ),
                                                const SizedBox(height: 24),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                                      color: const Color(0xFF0E1225),
                                border: Border.all(color: const Color(0xFF1F2937)),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(20.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Theme Configuration',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(height: 6),
                                        Text(
                                          'Upload your theme thumbnails.',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFFCCCCCC),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Checkbox(
                                              value: _noEffectsEnabled,
                                              onChanged: (value) {
                                                setState(() {
                                                  _noEffectsEnabled = value ?? false;
                                                });
                                                appState.toggleNoEffects();
                                              },
                                              activeColor: const Color(0xFFCC66FF),
                                              checkColor: Colors.white,
                                            ),
                                            const SizedBox(
                                              width: 140,
                                              child: Text(
                                                'Allow guests to take photos without AI',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 13,
                                                ),
                                                softWrap: true,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Padding(
                                                                padding: const EdgeInsets.only(left: 16),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF1F2937),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: const Color(0xFF374151)),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _buildDataSourceButton('Live', 'live'),
                                                _buildDataSourceButton('Post Delivery', 'post'),
                                              ],
                                            ),
                                          ),
                                        ),
                                        _buildCollectionFilter(appState),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    Expanded(
                                      child: Builder(
                                        builder: (context) {
                                          final list = _getFilteredPresets(appState);


                                          WidgetsBinding.instance.addPostFrameCallback((_) {
                                            if (!mounted) return;
                                            _preloadThumbnailsAroundViewport(context, list);
                                          });

                                          return NotificationListener<ScrollNotification>(
                                            onNotification: (n) {
                                              if (n.metrics.axis != Axis.vertical) return false;
                                              _preloadThumbnailsAroundViewport(context, list);
                                              return false;
                                            },
                                            child: ListView.builder(
                                              controller: _presetsScrollController,
                                            itemCount: list.length,
                                            itemBuilder: (context, index) {
                                              final preset = list[index];
                                              return _buildPresetCard(preset, index, appState);
                                            },
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                  ],
                                ),
                              ),
                            ),
                          ),
                                                const SizedBox(height: 34),
                          Row(
                            children: [
                              const Spacer(),
                              SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  onPressed: _isNavigating ? null : _onStartBooth,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFCC66FF),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(220, 48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: _isNavigating
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                          ),
                                        )
                                      : const Text(
                                          'Start Booth',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                ),
                              ),
                              const Spacer(),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (appState.currentUser != null)
                const Positioned(
                  left: 20,
                  bottom: 20,
                  child: UserProfileWidget(),
                ),
            ],
          );
        },
      ),
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
                        child: Consumer<AppState>(
        builder: (context, appState, child) {

          return Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  double leftPad = 265;
                  double rightPad = 120;
                  if (width < 1200) {
                    final scale = width / 1200;
                    leftPad = max(16, 265 * scale);
                    rightPad = max(16, 120 * scale);
                  }
                  const double shiftLeft = 50;
                  leftPad = max(0, leftPad - shiftLeft);
                  rightPad = rightPad + shiftLeft;
                  return Padding(
                    padding: EdgeInsets.fromLTRB(leftPad, 0, rightPad, 0),
                    child: Center(
                      child: Container(
                        width: double.infinity,
                                          constraints: const BoxConstraints(maxWidth: 945),
                        child: Padding(
                                            padding: const EdgeInsets.fromLTRB(24.0, 12.0, 24.0, 24.0),
                      child: Column(
                        children: [
                          Column(
                            children: [
                              const Text(
                                'Photobooth Setup',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Easily configure and manage your photobooth themes.',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFFCCCCCC),
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              _buildRealtimeIndicator(appState),
                            ],
                          ),
                                                const SizedBox(height: 24),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                                      color: const Color(0xFF0E1225),
                                border: Border.all(color: const Color(0xFF1F2937)),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(20.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Theme Configuration',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(height: 6),
                                        Text(
                                          'Upload your theme thumbnails.',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFFCCCCCC),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Checkbox(
                                              value: _noEffectsEnabled,
                                              onChanged: (value) {
                                                setState(() {
                                                  _noEffectsEnabled = value ?? false;
                                                });
                                                appState.toggleNoEffects();
                                              },
                                              activeColor: const Color(0xFFCC66FF),
                                              checkColor: Colors.white,
                                            ),
                                            const SizedBox(
                                              width: 140,
                                              child: Text(
                                              'Allow guests to take photos without AI',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                                ),
                                                softWrap: true,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Padding(
                                                                padding: const EdgeInsets.only(left: 16),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF1F2937),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: const Color(0xFF374151)),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _buildDataSourceButton('Live', 'live'),
                                                _buildDataSourceButton('Post Delivery', 'post'),
                                              ],
                                            ),
                                          ),
                                        ),
                                        _buildCollectionFilter(appState),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    Expanded(
                                      child: Builder(
                                        builder: (context) {
                                          final list = _getFilteredPresets(appState);


                                          WidgetsBinding.instance.addPostFrameCallback((_) {
                                            if (!mounted) return;
                                            _preloadThumbnailsAroundViewport(context, list);
                                          });

                                          return NotificationListener<ScrollNotification>(
                                            onNotification: (n) {
                                              if (n.metrics.axis != Axis.vertical) return false;
                                              _preloadThumbnailsAroundViewport(context, list);
                                              return false;
                                            },
                                            child: ListView.builder(
                                              controller: _presetsScrollController,
                                            itemCount: list.length,
                                            itemBuilder: (context, index) {
                                              final preset = list[index];
                                              return _buildPresetCard(preset, index, appState);
                                            },
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                  ],
                                ),
                              ),
                            ),
                          ),
                                                const SizedBox(height: 34),
                          Row(
                            children: [
                              const Spacer(),
                              SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  onPressed: _isNavigating ? null : _onStartBooth,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFCC66FF),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(220, 48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: _isNavigating
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                          ),
                                        )
                                      : const Text(
                                    'Start Booth',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              const Spacer(),
                            ],
                          ),
                        ],
                      ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (appState.currentUser != null)
                const Positioned(
                  left: 20,
                  bottom: 20,
                  child: UserProfileWidget(),
                ),
            ],
          );
        },
      ),
                      ),
                    )
                  : FittedBox(
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: _baseWidth,
                        height: effectiveBaseHeight,
                        child: Consumer<AppState>(
        builder: (context, appState, child) {
          assert(() {
            return true;
          }());
          
          return Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  double leftPad = 265;
                  double rightPad = 120;
                  if (width < 1200) {
                    final scale = width / 1200;
                    leftPad = max(16, 265 * scale);
                    rightPad = max(16, 120 * scale);
                  }
                  const double shiftLeft = 50;
                  leftPad = max(0, leftPad - shiftLeft);
                  rightPad = rightPad + shiftLeft;
                  return Padding(
                    padding: EdgeInsets.fromLTRB(leftPad, 0, rightPad, 0),
                    child: Center(
                      child: Container(
                        width: double.infinity,
                                    constraints: const BoxConstraints(maxWidth: 945),
                        child: Padding(
                                      padding: const EdgeInsets.fromLTRB(24.0, 12.0, 24.0, 24.0),
                      child: Column(
                        children: [
                          Column(
                            children: [
                              const Text(
                                'Photobooth Setup',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Easily configure and manage your photobooth themes.',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFFCCCCCC),
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              _buildRealtimeIndicator(appState),
                            ],
                          ),
                                          const SizedBox(height: 24),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                                color: const Color(0xFF0E1225),
                                border: Border.all(color: const Color(0xFF1F2937)),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(20.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Theme Configuration',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                        SizedBox(height: 6),
                                        Text(
                                          'Upload your theme thumbnails',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFFCCCCCC),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Checkbox(
                                              value: _noEffectsEnabled,
                                              onChanged: (value) {
                                                setState(() {
                                                  _noEffectsEnabled = value ?? false;
                                                });
                                                appState.toggleNoEffects();
                                              },
                                              activeColor: const Color(0xFFCC66FF),
                                              checkColor: Colors.white,
                                            ),
                                            const SizedBox(
                                              width: 140,
                                              child: Text(
                                                'Allow guests to take photos without AI',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                                ),
                                                softWrap: true,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Padding(
                                                          padding: const EdgeInsets.only(left: 16),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF1F2937),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: const Color(0xFF374151)),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _buildDataSourceButton('Live', 'live'),
                                                _buildDataSourceButton('Post Delivery', 'post'),
                                              ],
                                            ),
                                          ),
                                        ),
                                        _buildCollectionFilter(appState),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    Expanded(
                                      child: Builder(
                                        builder: (context) {
                                          final list = _getFilteredPresets(appState);


                                          WidgetsBinding.instance.addPostFrameCallback((_) {
                                            if (!mounted) return;
                                            _preloadThumbnailsAroundViewport(context, list);
                                          });

                                          return NotificationListener<ScrollNotification>(
                                            onNotification: (n) {
                                              if (n.metrics.axis != Axis.vertical) return false;
                                              _preloadThumbnailsAroundViewport(context, list);
                                              return false;
                                            },
                                            child: ListView.builder(
                                              controller: _presetsScrollController,
                                            itemCount: list.length,
                                            itemBuilder: (context, index) {
                                              final preset = list[index];
                                              return _buildPresetCard(preset, index, appState);
                                            },
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                  ],
                                ),
                              ),
                            ),
                          ),
                                          const SizedBox(height: 34),
                          Row(
                            children: [
                              const Spacer(),
                              SizedBox(
                                height: 48,
                                child: ElevatedButton(
                                  onPressed: _isNavigating ? null : _onStartBooth,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFCC66FF),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(220, 48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: _isNavigating
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                          ),
                                        )
                                      : const Text(
                                    'Start Booth',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              const Spacer(),
                            ],
                          ),
                        ],
                      ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (appState.currentUser != null)
                const Positioned(
                  left: 20,
                  bottom: 20,
                  child: UserProfileWidget(),
                ),
            ],
          );
        },
                ),
                ),
              ),
            );
          },
        ),
        ),
      ),
    );
  }

  Future<bool> _confirmExitDialog() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2937),
              title: const Text('Exit App?', style: TextStyle(color: Colors.white)),
              content: const Text(
                'Are you sure you want to exit?',
                style: TextStyle(color: Color(0xFF9CA3AF)),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF9CA3AF))),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Yes', style: TextStyle(color: Color(0xFFCC66FF))),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Widget _buildDataSourceButton(String label, String value) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        final isSelected = appState.dataSource == value;
        return GestureDetector(
          onTap: () {
            setState(() {
              appState.setDataSource(value);
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFFCC66FF) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : const Color(0xFF9CA3AF),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPresetCard(Preset preset, int index, AppState appState) {

    
    return Container(
      key: ValueKey('${appState.dataSource}-${preset.presetId}'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(8, 5, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        border: Border.all(color: const Color(0xFF374151)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

          Padding(
            padding: const EdgeInsets.only(top: 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [

              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(6),
                ),
                    child: ThumbnailCacheService.instance.isSupportedImageSource(preset.generatedImageUrls)
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                          child: Builder(
                            builder: (context) {
                              final dpr = MediaQuery.of(context).devicePixelRatio;
                              return Image(
                              image: ThumbnailCacheService.instance.providerForResized(
                              preset.generatedImageUrls,
                                  cacheWidth: (120 * dpr).round(),
                                  cacheHeight: (120 * dpr).round(),
                              ),
                              key: ValueKey('img-${appState.dataSource}-${preset.presetId}-${preset.generatedImageUrls}'),
                                fit: BoxFit.contain,
                                alignment: Alignment.center,
                                filterQuality: FilterQuality.high,
                              gaplessPlayback: true,
                              loadingBuilder: (context, child, loadingProgress) {
                                if (loadingProgress == null) return child;
                                assert(() {
                                  print("ðŸ“¥ Loading image for '${preset.title}': ${loadingProgress.cumulativeBytesLoaded} / ${loadingProgress.expectedTotalBytes ?? 'unknown'}");
                                  return true;
                                }());
                                return Center(
                                  child: CircularProgressIndicator(
                                    value: loadingProgress.expectedTotalBytes != null
                                        ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                                        : null,
                                  ),
                                );
                              },
                              errorBuilder: (context, error, stackTrace) {
                                assert(() {
                                  print("âŒ Error loading image for '${preset.title}' from URL: ${preset.generatedImageUrls}");
                                  print("   Error: $error");
                                  return true;
                                }());
                                return Container(
                                  width: 48,
                                  height: 48,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF374151),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                        color: const Color(0xFF7C3AED),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFF6B7280), width: 1),
                                    ),
                                  ),
                                  );
                                },
                                );
                              },
                            ),
                          )
                        : Container(
                            width: 48,
                            height: 48,
                            decoration: const BoxDecoration(
                              color: Color(0xFF374151),
                              shape: BoxShape.circle,
                            ),
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: const Color(0xFF7C3AED),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFF6B7280), width: 1),
                              ),
                            ),
                          ),
              ),
              
              const SizedBox(height: 8),

                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => _onBrowseImage(index, appState),
                      child: Container(
                        width: 70,
                        height: 28,
                        decoration: BoxDecoration(
                          color: const Color(0xFF080C1B),
                          border: Border.all(color: const Color(0xFF374151)),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Center(
                          child: Text(
                            'ðŸ—‚ï¸',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.white,
                            ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
            ),
          ),
          
          const SizedBox(width: 7),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Row(
                    children: [
                      const Text(
                        'Title:',
                        style: TextStyle(
                          color: Color(0xFF9CA3AF),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),

                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 667),
                  height: 33,
                  decoration: BoxDecoration(
                    color: const Color(0xFF080C1B),
                    border: Border.all(color: const Color(0xFF374151)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                      child: Builder(
                        builder: (context) {
                          final controller = _titleControllerFor(preset);

                          if (controller.text != preset.title && !controller.selection.isValid) {
                            controller.text = preset.title;
                          }
                          return IgnorePointer(
                            ignoring: true,
                            child: TextFormField(
                        key: ValueKey('title-${appState.dataSource}-${preset.presetId}'),
                        controller: controller,
                              readOnly: true,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          hintText: 'Theme name',
                          hintStyle: TextStyle(
                            color: Color(0xFF6B7280),
                            fontSize: 14,
                          ),
                        ),
                            ),
                          );
                        },
                      ),
                ),
                
                const SizedBox(height: 8),

                const Text(
                  'Prompt',
                  style: TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),

                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => _escFocusNode.requestFocus(),
                  onDoubleTap: () {
                    Clipboard.setData(ClipboardData(text: preset.prompt));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Prompt copied'),
                        backgroundColor: Color(0xFF10B981),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                  child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 667),
                    height: 60,
                  decoration: BoxDecoration(
                    color: const Color(0xFF080C1B),
                    border: Border.all(color: const Color(0xFF374151)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: SelectionArea(
                        child: Text(
                          (preset.prompt.isNotEmpty ? preset.prompt : 'No prompt provided.'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.2),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Builder(
                    builder: (context) {
                      final isPost = preset.postProcessingUrl.toLowerCase().contains('post-delivery');
                      final creditText = isPost ? '0.5 credits' : '0.3 credits';
                      final bg = isPost ? const Color(0xFF201219) : const Color(0xFF131A12);
                      final bd = isPost ? const Color(0xFF502337) : const Color(0xFF2A3A2A);
                      final fg = isPost ? const Color(0xFFF087A5) : const Color(0xFF84E18D);
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                          color: bg,
                          border: Border.all(color: bd),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.currency_exchange, size: 14, color: fg),
                            const SizedBox(width: 6),
                            Text(
                              creditText,
                              style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }


  String _generateRandomId(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(
      Iterable.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  String _getValidDropdownValue(String currentValue, List<Collection> collections) {

    final collectionNames = collections.map((c) => c.name).toList();

    if (collectionNames.contains(currentValue)) {
      return currentValue;
    }

    if (collectionNames.contains('Default')) {
      return 'Default';
    }

    return 'Default';
  }

  List<DropdownMenuItem<String>> _buildDropdownItems(List<Collection> collections) {
    final items = <DropdownMenuItem<String>>[];
    final addedValues = <String>{};

    final collectionNames = collections.map((c) => c.name).toList();
    if (!collectionNames.contains('Default')) {
      items.add(const DropdownMenuItem(
        value: 'Default',
        child: SizedBox(width: 180, child: Text('Default', overflow: TextOverflow.ellipsis)),
      ));
      addedValues.add('Default');
    }

    for (final collection in collections) {
      if (!addedValues.contains(collection.name)) {
        items.add(DropdownMenuItem(
          value: collection.name,
          child: SizedBox(width: 180, child: Text(collection.name, overflow: TextOverflow.ellipsis)),
        ));
        addedValues.add(collection.name);
      }
    }
    
    return items;
  }


  void _onBrowseImage(int index, AppState appState) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        if (index < 0 || index >= appState.presets.length) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Selected preset is no longer available.'),
              backgroundColor: Color(0xFFEF4444),
            ),
          );
          return;
        }

        final currentPreset = appState.presets[index];
        final presetId = currentPreset.presetId;
        if (presetId.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Invalid preset selected.'),
              backgroundColor: Color(0xFFEF4444),
            ),
          );
          return;
        }

        final file = File(result.files.single.path!);
        final presetService = PresetService();

        if (!mounted) return;
        bool dialogShown = false;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(
            child: CircularProgressIndicator(
              color: Color(0xFFCC66FF),
            ),
          ),
        );
        dialogShown = true;

        try {
          await LogService.log('ThumbSelect:start presetIndex=$index file=${file.path}');

          final imageUrl = await presetService.uploadImage(file, presetId);

          await LogService.log('ThumbSelect:uploaded url=$imageUrl for presetId=${currentPreset.presetId}');

          await presetService.appendGeneratedImageUrlToPreset(currentPreset, imageUrl);
          await LogService.log('ThumbSelect:append complete presetId=${currentPreset.presetId}');

          if (!mounted) return;
          if (dialogShown && Navigator.of(context).canPop()) {
          Navigator.pop(context);
            dialogShown = false;
          }
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image uploaded successfully!'),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        } catch (e) {

          if (!mounted) return;
          if (dialogShown && Navigator.of(context).canPop()) {
          Navigator.pop(context);
            dialogShown = false;
          }
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to upload image: $e'),
              backgroundColor: const Color(0xFFEF4444),
            ),
          );
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error selecting image: $e'),
          backgroundColor: const Color(0xFFEF4444),
        ),
      );
    }
  }

  void _onStartBooth() async {

    if (_isNavigating) return;

    if (!mounted) return;
    
    setState(() {
      _isNavigating = true;
    });
    
    try {

      await Future.delayed(const Duration(milliseconds: 50));
      
      if (!mounted) return;

      await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => BoothSelectionScreen(
          collectionFilter: _selectedCollectionFilter,
        ),
      ),
    );
    } catch (e) {

      print('Error navigating to booth selection: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isNavigating = false;
        });
      }
    }
  }

  Widget _buildRealtimeIndicator(AppState appState) {
    final isConnected = appState.isRealtimeListening;
    
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: isConnected ? Colors.green : Colors.red,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          isConnected ? 'Real-time sync active' : 'Offline mode',
          style: TextStyle(
            fontSize: 12,
            color: isConnected ? Colors.green : Colors.red,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  List<Preset> _getFilteredPresets(AppState appState) {

    
    if (_selectedCollectionFilter == null) return appState.presets;

    if (_cachedFilteredPresets != null &&
        identical(_cachedPresetsRef, appState.presets) &&
        _cachedCollectionFilter == _selectedCollectionFilter) {
      return _cachedFilteredPresets!;
    }

    assert(() {
      return true;
    }());
    
    final filtered = appState.presets.where((preset) {
      final matches = preset.collection == _selectedCollectionFilter;
      return matches;
    }).toList();
    
    assert(() {
      return true;
    }());
    _cachedPresetsRef = appState.presets;
    _cachedCollectionFilter = _selectedCollectionFilter;
    _cachedFilteredPresets = filtered;
    return _cachedFilteredPresets!;
  }

  Widget _buildCollectionFilter(AppState appState) {


    if (_selectedCollectionFilter != null && 
        appState.collections.isNotEmpty &&
        !appState.collections.any((c) => c.name == _selectedCollectionFilter)) {

      assert(() {
        return true;
      }());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _selectedCollectionFilter = null;
        });
      });
    }
    
    return SizedBox(
      width: 200,
      height: 36,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned(
            top: -28,
            left: 0,
            child: Text(
              'Select a collection for the event',
              style: TextStyle(
                color: Color(0xFF9CA3AF),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          StatefulBuilder(
      builder: (context, localSetState) {
        bool isHovered = false;
        bool isFocused = false;
        
        return MouseRegion(
          onEnter: (_) => localSetState(() => isHovered = true),
          onExit: (_) => localSetState(() => isHovered = false),
          child: Focus(
            onFocusChange: (hasFocus) => localSetState(() => isFocused = hasFocus),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 200,
              height: 36,
              decoration: BoxDecoration(
                color: isFocused 
                    ? const Color(0xFF1F2937).withOpacity(0.9)
                    : isHovered 
                        ? const Color(0xFF1F2937).withOpacity(0.8)
                        : const Color(0xFF1F2937),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isFocused 
                      ? const Color(0xFF7C3AED)
                      : isHovered
                          ? const Color(0xFF7C3AED).withOpacity(0.5)
                          : const Color(0xFF374151),
                  width: isFocused ? 2 : 1,
                ),
                boxShadow: isFocused ? [
                  BoxShadow(
                    color: const Color(0xFF7C3AED).withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ] : isHovered ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ] : null,
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton2<String>(
                  value: _selectedCollectionFilter,
                  hint: const Text(
                    'Filter by Collection',
                    style: TextStyle(
                      color: Color(0xFF9CA3AF),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  items: _buildCollectionFilterItems(appState.collections),
                  onChanged: (value) {
                    assert(() {
                      return true;
                    }());
                    setState(() {
                      _selectedCollectionFilter = value;
                    });
                  },
                  buttonStyleData: const ButtonStyleData(
                    width: 200,
                    padding: EdgeInsets.symmetric(horizontal: 8),
                  ),
                  dropdownStyleData: const DropdownStyleData(
                    maxHeight: 280,
                    width: 200,
                    decoration: BoxDecoration(color: Color(0xFF1F2937)),
                  ),
                  menuItemStyleData: const MenuItemStyleData(
                    height: 32,
                    padding: EdgeInsets.symmetric(horizontal: 8),
                  ),
                  iconStyleData: const IconStyleData(
                    icon: ChevronWidget(isUpward: false, color: Color(0xFF7C3AED), size: 10),
                  ),
                  onMenuStateChange: (isOpen) {
                    if (!isOpen) {
                      _escFocusNode.requestFocus();
                    }
                  },
                ),
              ),
            ),
          ),
        );
      },
        ),
        ],
      ),
    );
  }

  List<DropdownMenuItem<String>> _buildCollectionFilterItems(List<Collection> collections) {
    if (_cachedCollectionItems != null && identical(_cachedCollectionsRef, collections)) {
      return _cachedCollectionItems!;
    }
    final items = <DropdownMenuItem<String>>[];

    assert(() {
      return true;
    }());

    items.add(const DropdownMenuItem<String>(
      value: null,
      child: SizedBox(
        width: 168,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          'All Collections',
          style: TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      )),
    ));

    for (final collection in collections) {
      items.add(DropdownMenuItem<String>(
        value: collection.name,
        child: SizedBox(
          width: 168,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            collection.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        )),
      ));
    }
    
    _cachedCollectionsRef = collections;
    _cachedCollectionItems = items;
    return items;
  }
}

