import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
import '../services/log_service.dart';
import 'dart:io';
import 'dart:math';
import '../providers/app_state.dart';
import '../widgets/user_profile_widget.dart';
import '../widgets/chevron_widget.dart';
import '../services/preset_service.dart';
import '../models/preset.dart';
import '../models/collection.dart';
import 'booth_selection_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WindowListener {
  // Base canvas to maintain proportions across any display
  static const double _baseWidth = 1920;
  static const double _baseHeight = 1080;
  final FocusNode _escFocusNode = FocusNode();
  bool _noEffectsEnabled = false;
  String? _selectedCollectionFilter; // null means show all collections
  String _lastDataSource = 'live'; // Track last data source to detect changes
  // Stable controllers for title fields per presetId
  final Map<String, TextEditingController> _titleControllers = {};

  TextEditingController _titleControllerFor(Preset preset) {
    return _titleControllers.putIfAbsent(
      preset.presetId,
      () => TextEditingController(text: preset.title),
    );
  }

  @override
  void initState() {
    super.initState();
    _enterFullscreenFrameless();
    windowManager.addListener(this);
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
    _escFocusNode.dispose();
    for (final controller in _titleControllers.values) {
      controller.dispose();
    }
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
              // ignore: use_build_context_synchronously
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
            final canRenderOneToOne = viewport.maxWidth >= _baseWidth && viewport.maxHeight >= effectiveBaseHeight;

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
          // build
          if (_lastDataSource != appState.dataSource) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              setState(() {
                _lastDataSource = appState.dataSource;
                _selectedCollectionFilter = null;
              });
            });
          }
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
                                          'Upload your theme thumbnails and add URL details below.',
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
                                            const Text(
                                              'No effects',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Padding(
                                                                padding: const EdgeInsets.only(left: 100),
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
                                          return ListView.builder(
                                            itemCount: list.length,
                                            itemBuilder: (context, index) {
                                              final preset = list[index];
                                              return _buildPresetCard(preset, index, appState);
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    SizedBox(
                                      width: double.infinity,
                                      height: 40,
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: ElevatedButton(
                                          onPressed: () => _onAddTheme(appState),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.transparent,
                                            foregroundColor: Colors.white,
                                            side: const BorderSide(
                                              color: Color(0xFF080C1B),
                                              width: 2,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            elevation: 0,
                                            padding: const EdgeInsets.all(8),
                                          ).copyWith(
                                            backgroundColor: MaterialStateProperty.resolveWith<Color?>(
                                              (Set<MaterialState> states) {
                                                if (states.contains(MaterialState.hovered)) {
                                                                        return const Color(0xFFCC66FF);
                                                }
                                                return Colors.transparent;
                                              },
                                            ),
                                          ),
                                          child: const Text(
                                            '+  Add a new theme',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
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
                                  onPressed: _onStartBooth,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFCC66FF),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(220, 48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: const Text(
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
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: _baseWidth,
                        height: effectiveBaseHeight,
                        child: Consumer<AppState>(
        builder: (context, appState, child) {
          print("🔄 MainScreen Consumer rebuild - dataSource: ${appState.dataSource}, presets: ${appState.presets.length}");
          if (_lastDataSource != appState.dataSource) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              setState(() {
                _lastDataSource = appState.dataSource;
                _selectedCollectionFilter = null;
              });
            });
          }
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
                                          'Upload your theme thumbnails and add URL details below.',
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
                                            const Text(
                                              'No effects',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Padding(
                                                          padding: const EdgeInsets.only(left: 100),
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
                                          return ListView.builder(
                                            itemCount: list.length,
                                            itemBuilder: (context, index) {
                                              final preset = list[index];
                                              return _buildPresetCard(preset, index, appState);
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(height: 20),
                                    SizedBox(
                                      width: double.infinity,
                                      height: 40,
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: ElevatedButton(
                                          onPressed: () => _onAddTheme(appState),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.transparent,
                                            foregroundColor: Colors.white,
                                            side: const BorderSide(
                                              color: Color(0xFF080C1B),
                                              width: 2,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            elevation: 0,
                                            padding: const EdgeInsets.all(8),
                                          ).copyWith(
                                            backgroundColor: MaterialStateProperty.resolveWith<Color?>(
                                              (Set<MaterialState> states) {
                                                if (states.contains(MaterialState.hovered)) {
                                                                  return const Color(0xFFCC66FF);
                                                }
                                                return Colors.transparent;
                                              },
                                            ),
                                          ),
                                          child: const Text(
                                            '+  Add a new theme',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
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
                                  onPressed: _onStartBooth,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFCC66FF),
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(220, 48),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: const Text(
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
    // build preset card
    
    return Container(
      key: ValueKey('${appState.dataSource}-${preset.presetId}'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(8, 5, 12, 12), // Exact padding from legacy
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        border: Border.all(color: const Color(0xFF374151)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // Left side - Image and browse button (exact dimensions from legacy)
          Padding(
            padding: const EdgeInsets.only(top: 15), // Move thumbnail down by 5 pixels
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
              // Theme thumbnail - made bigger (120x120)
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: const Color(0xFF111827), // Exact color from legacy
                  borderRadius: BorderRadius.circular(6), // Exact radius from legacy
                ),
                    child: preset.generatedImageUrls.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.network(
                              preset.generatedImageUrls,
                              key: ValueKey('img-${appState.dataSource}-${preset.presetId}-${preset.generatedImageUrls}'),
                              fit: BoxFit.cover,
                              cacheWidth: 120,
                              cacheHeight: 120,
                              gaplessPlayback: true,
                              loadingBuilder: (context, child, loadingProgress) {
                                if (loadingProgress == null) return child;
                                assert(() {
                                  // ignore: avoid_print
                                  print("📥 Loading image for '${preset.title}': ${loadingProgress.cumulativeBytesLoaded} / ${loadingProgress.expectedTotalBytes ?? 'unknown'}");
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
                                  // ignore: avoid_print
                                  print("❌ Error loading image for '${preset.title}' from URL: ${preset.generatedImageUrls}");
                                  // ignore: avoid_print
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
                                      color: const Color(0xFF7C3AED), // PRIMARY color from legacy
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFF6B7280), width: 1),
                                    ),
                                  ),
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
                                color: const Color(0xFF7C3AED), // PRIMARY color from legacy
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: const Color(0xFF6B7280), width: 1),
                              ),
                            ),
                          ),
              ),
              
              const SizedBox(height: 8), // Exact spacing from legacy
              
                  // Browse button - moved down 5 pixels
                  Padding(
                    padding: const EdgeInsets.only(top: 6), // Move down by 5 pixels
                    child: GestureDetector(
                      onTap: () => _onBrowseImage(index, appState),
                      child: Container(
                        width: 70,
                        height: 28,
                        decoration: BoxDecoration(
                          color: const Color(0xFF080C1B), // Exact color from legacy
                          border: Border.all(color: const Color(0xFF374151)),
                          borderRadius: BorderRadius.circular(14), // Exact radius from legacy
                        ),
                        child: Center(
                          child: Text(
                            '🗂️',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.white,
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
          
          // Right side content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title row with delete button
                Padding(
                  padding: const EdgeInsets.only(top: 7), // Move down by 5 pixels
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
                      Transform.translate(
                        offset: const Offset(-3, 0), // Move 2 pixels to the left
                        child: IconButton(
                              onPressed: () => appState.deletePreset(index),
                          icon: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xFFDC2626).withOpacity(0.3),
                                width: 1,
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            padding: const EdgeInsets.all(2), // 2x2px inset
                            child: const Text(
                              '🗑️',
                              style: TextStyle(
                                fontSize: 16,
                                color: Color(0xFFDC2626),
                              ),
                            ),
                          ),
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Title input field - fluid width with max 667, height 33
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
                          // If model changed externally, sync when not actively editing
                          if (controller.text != preset.title && !controller.selection.isValid) {
                            controller.text = preset.title;
                          }
                          return TextFormField(
                        key: ValueKey('title-${appState.dataSource}-${preset.presetId}'),
                        controller: controller,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14, // Exact font size from legacy
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6), // Exact padding from legacy
                          hintText: 'Theme name',
                          hintStyle: TextStyle(
                            color: Color(0xFF6B7280),
                            fontSize: 14,
                          ),
                        ),
                        onChanged: (value) {
                          final updatedPreset = preset.copyWith(title: value);
                          appState.updatePreset(index, updatedPreset);
                          // Debounced save to Firebase - exactly like legacy app
                          final presetService = PresetService();
                          presetService.debouncedSavePresetFieldById(preset.presetId, 'name', value);
                        },
                          );
                        },
                      ),
                ),
                
                const SizedBox(height: 6), // Reduced spacing
                
                // Collection label
                const Text(
                  'Collection:',
                  style: TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                
                // Collection dropdown - fluid width with max 667, height 33
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 667),
                  height: 33,
                  decoration: BoxDecoration(
                    color: const Color(0xFF080C1B),
                    border: Border.all(color: const Color(0xFF374151)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DropdownButtonFormField2<String>(
                    key: ValueKey('collection-${appState.dataSource}-${preset.presetId}-${preset.collection}'),
                    value: _getValidDropdownValue(preset.collection, appState.collections),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14, // Exact font size from legacy
                    ),
                    dropdownStyleData: const DropdownStyleData(
                      maxHeight: 280,
                      width: 360,
                      decoration: BoxDecoration(color: Color(0xFF1F2937)),
                    ),
                    menuItemStyleData: const MenuItemStyleData(
                      height: 32,
                      padding: EdgeInsets.symmetric(horizontal: 12),
                    ),
                    buttonStyleData: const ButtonStyleData(
                      width: 360,
                    ),
                    iconStyleData: const IconStyleData(
                      icon: ChevronWidget(isUpward: false, color: Color(0xFF7C3AED), size: 12),
                    ),
                    onMenuStateChange: (isOpen) {
                      if (!isOpen) {
                        _escFocusNode.requestFocus();
                      }
                    },
                    items: _buildDropdownItems(appState.collections),
                    onChanged: (value) {
                      if (value == '+ Create New Collection...') {
                        _showCreateCollectionDialog(context, appState, index, preset);
                      } else {
                        _onCollectionChanged(index, value ?? 'Default', appState, preset);
                      }
                    },
                  ),
                ),
                
                const SizedBox(height: 6), // Reduced spacing
                
                // API endpoint label
                const Text(
                  'API endpoint:',
                  style: TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                
                // API endpoint input - fluid width with max 667, height 33
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 667),
                  height: 33,
                  decoration: BoxDecoration(
                    color: const Color(0xFF080C1B),
                    border: Border.all(color: const Color(0xFF374151)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                      child: TextFormField(
                        key: ValueKey('url-${appState.dataSource}-${preset.presetId}-${preset.postProcessingUrl}'),
                        initialValue: preset.postProcessingUrl,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14, // Exact font size from legacy
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 6), // Exact padding from legacy
                          hintText: 'https://example.com/process-image',
                          hintStyle: TextStyle(
                            color: Color(0xFF6B7280),
                            fontSize: 14,
                          ),
                        ),
                        onChanged: (value) {
                          final updatedPreset = preset.copyWith(postProcessingUrl: value);
                          appState.updatePreset(index, updatedPreset);
                          // Debounced save to Firebase - exactly like legacy app
                          final presetService = PresetService();
                          presetService.debouncedSavePresetFieldById(preset.presetId, 'url', value);
                        },
                      ),
                ),
                
                const SizedBox(height: 4), // Reduced spacing to prevent overflow
                
                // Helper text
                const Text(
                  'The URL where the photo will be sent for processing (optional).',
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontSize: 11,
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


  void _onAddTheme(AppState appState) {
    // Create new preset exactly like legacy app
    final newPreset = Preset(
      url: "",
      name: "Untitled Theme",
      thumbnailPath: "",
      title: "Untitled Theme",
      postProcessingUrl: "",
      generatedImageUrls: "https://firebasestorage.googleapis.com/v0/b/ai-booth-edda3.firebasestorage.app/o/generations%2F1yOQlRrxwrOvv6L5urQM4pTTTFV2%2Finputs%2Fsecond%2F1760111631964_1760111619628_fk0nq2_0_WhatsApp%20Image%202025-10-10%20at%208.51.04%20PM.jpeg?alt=media&token=fd6cc553-5084-4684-9ba3-3ec036f9b384",
      createdAt: DateTime.now().millisecondsSinceEpoch.toString(),
      presetId: _generateRandomId(8), // Generate random 8-character ID
      collectionId: "", // Will be inherited from collection when saved
      collection: "Default",
    );
    
    appState.addPreset(newPreset);
    
    // Scroll to bottom to show the new card (like legacy app)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scrollController = Scrollable.of(context);
      if (scrollController != null) {
        scrollController.position.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Generate random ID like legacy app
  String _generateRandomId(int length) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    return String.fromCharCodes(
      Iterable.generate(length, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  // Get valid dropdown value to prevent duplicate value errors
  String _getValidDropdownValue(String currentValue, List<Collection> collections) {
    // Always ensure "Default" exists in the dropdown
    final collectionNames = collections.map((c) => c.name).toList();
    
    // If current value exists in collections, use it
    if (collectionNames.contains(currentValue)) {
      return currentValue;
    }
    
    // If "Default" exists, use it
    if (collectionNames.contains('Default')) {
      return 'Default';
    }
    
    // If no collections exist, return "Default" (it will be added to dropdown)
    return 'Default';
  }

  // Build dropdown items with unique values
  List<DropdownMenuItem<String>> _buildDropdownItems(List<Collection> collections) {
    final items = <DropdownMenuItem<String>>[];
    final addedValues = <String>{}; // Track added values to prevent duplicates
    
    // Add "Default" collection if it doesn't exist in collections
    final collectionNames = collections.map((c) => c.name).toList();
    if (!collectionNames.contains('Default')) {
      items.add(const DropdownMenuItem(
        value: 'Default',
        child: SizedBox(width: 180, child: Text('Default', overflow: TextOverflow.ellipsis)),
      ));
      addedValues.add('Default');
    }
    
    // Add all existing collections (avoid duplicates)
    for (final collection in collections) {
      if (!addedValues.contains(collection.name)) {
        items.add(DropdownMenuItem(
          value: collection.name,
          child: SizedBox(width: 180, child: Text(collection.name, overflow: TextOverflow.ellipsis)),
        ));
        addedValues.add(collection.name);
      }
    }
    
    // Add "Create New Collection" option
    items.add(const DropdownMenuItem(
      value: '+ Create New Collection...',
      child: SizedBox(width: 180, child: Text('+ Create New Collection...', overflow: TextOverflow.ellipsis)),
    ));
    
    return items;
  }

  void _showCreateCollectionDialog(BuildContext context, AppState appState, int index, Preset preset) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F2937),
        title: const Text(
          'New Collection',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter collection name:',
            hintStyle: TextStyle(color: Color(0xFF6B7280)),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                final collectionName = controller.text.trim();
                Navigator.pop(context);
                _onCollectionChanged(index, collectionName, appState, preset);
              }
            },
            child: const Text('Create', style: TextStyle(color: Color(0xFFCC66FF))),
          ),
        ],
      ),
    );
  }

  // Handle collection dropdown change - exactly like legacy app
  void _onCollectionChanged(int index, String collectionName, AppState appState, Preset preset) {
    // Update the preset's collection in memory - exactly like legacy
    final oldCollection = preset.collection;
    final updatedPreset = preset.copyWith(collection: collectionName);
    
    // Check if collection already exists to avoid duplicates
    final existingCollection = appState.collections.firstWhere(
      (collection) => collection.name == collectionName,
      orElse: () => Collection(id: '', name: '', description: ''),
    );
    
    String collectionId;
    if (existingCollection.name.isNotEmpty) {
      // Use existing collection ID (8-character random string)
      collectionId = existingCollection.id; // Use the 8-character ID
    } else {
      // Generate random collection ID (8 characters) only for new collections
      collectionId = _generateRandomId(8);
      // Create collection document in Firebase only for new collections
      _createCollectionInFirebase(collectionName, collectionId);
    }
    
    final presetWithCollectionId = updatedPreset.copyWith(collectionId: collectionId);
    
    // Update preset in app state
    appState.updatePreset(index, presetWithCollectionId);
    
    // Use debounced save with field-level updates (prevents Firestore duplication) - exactly like legacy
    final presetService = PresetService();
    presetService.debouncedSavePresetFieldById(preset.presetId, 'collection', collectionName);
  }

  // Create collection in Firebase - exactly like legacy app
  void _createCollectionInFirebase(String collectionName, String collectionId) async {
    try {
      final presetService = PresetService();
      await presetService.createCollectionInFirebase(collectionName, collectionId);
    } catch (e) {
      print(" Error creating collection in Firebase: $e");
    }
  }

  void _onBrowseImage(int index, AppState appState) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final presetService = PresetService();
        
        // Show loading indicator
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(
            child: CircularProgressIndicator(
              color: Color(0xFFCC66FF),
            ),
          ),
        );

        try {
          await LogService.log('ThumbSelect:start presetIndex=$index file=${file.path}');
          // Upload image to Firebase Storage
          final imageUrl = await presetService.uploadImage(file, appState.presets[index].presetId);
          
          // Update preset locally and append in Firebase atomically
          final currentPreset = appState.presets[index];
          await LogService.log('ThumbSelect:uploaded url=$imageUrl for presetId=${currentPreset.presetId}');
          final updatedPreset = currentPreset.copyWith(generatedImageUrls: imageUrl);
          await appState.updatePreset(index, updatedPreset);
          await presetService.appendGeneratedImageUrlToPreset(currentPreset, imageUrl);
          await LogService.log('ThumbSelect:append complete presetId=${currentPreset.presetId}');
          
          // Close loading dialog
          Navigator.pop(context);
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image uploaded successfully!'),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        } catch (e) {
          // Close loading dialog
          Navigator.pop(context);
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to upload image: $e'),
              backgroundColor: const Color(0xFFEF4444),
            ),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error selecting image: $e'),
          backgroundColor: const Color(0xFFEF4444),
        ),
      );
    }
  }

  void _onStartBooth() {
    // Navigate to booth selection screen
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const BoothSelectionScreen(),
      ),
    );
  }

  /// Build real-time connection indicator
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

  // Get filtered presets based on selected collection
  List<Preset> _getFilteredPresets(AppState appState) {
    // filter presets
    
    if (_selectedCollectionFilter == null) {
      // returning all presets
      return appState.presets; // Show all presets
    }
    
    final filtered = appState.presets.where((preset) => preset.collection == _selectedCollectionFilter).toList();
    return filtered;
  }

  // Build enhanced collection filter dropdown
  Widget _buildCollectionFilter(AppState appState) {
    // Validate that selected collection exists in current data source
    if (_selectedCollectionFilter != null && 
        !appState.collections.any((c) => c.name == _selectedCollectionFilter)) {
      // Reset filter if selected collection doesn't exist in current data source
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _selectedCollectionFilter = null;
        });
      });
    }
    
    return StatefulBuilder(
      builder: (context, setState) {
        bool isHovered = false;
        bool isFocused = false;
        
        return MouseRegion(
          onEnter: (_) => setState(() => isHovered = true),
          onExit: (_) => setState(() => isHovered = false),
          child: Focus(
            onFocusChange: (hasFocus) => setState(() => isFocused = hasFocus),
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
    );
  }

  // Build collection filter dropdown items
  List<DropdownMenuItem<String>> _buildCollectionFilterItems(List<Collection> collections) {
    final items = <DropdownMenuItem<String>>[];
    
    // Add "All Collections" option
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
    
    // Add each collection
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
    
    return items;
  }
}