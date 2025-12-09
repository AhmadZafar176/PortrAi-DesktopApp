import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'services/file_processing_service.dart';
import 'services/session_service.dart';
import 'widgets/processing_overlay.dart';

class WorkerOverlayApp extends StatefulWidget {
  final List<String> files;
  const WorkerOverlayApp({super.key, required this.files});

  @override
  State<WorkerOverlayApp> createState() => _WorkerOverlayAppState();
}

class _WorkerOverlayAppState extends State<WorkerOverlayApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _initWorkerWindow();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _initWorkerWindow() async {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setFullScreen(true);
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PortrAI - Processing',
      home: _WorkerOverlayScreen(files: widget.files),
    );
  }
}

class _WorkerOverlayScreen extends StatefulWidget {
  final List<String> files;
  const _WorkerOverlayScreen({required this.files});

  @override
  State<_WorkerOverlayScreen> createState() => _WorkerOverlayScreenState();
}

class _WorkerOverlayScreenState extends State<_WorkerOverlayScreen> {
  static const double _baseWidth = 1920;
  static const double _baseHeight = 1080;
  bool _showDoneButton = false;
  int _exitCode = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      OverlayManager.showProcessing(context, 'Waiting for processed image…');
      final code = await FileProcessingService.processFilesHeadless(widget.files);
      OverlayManager.hideOverlay();
      _exitCode = code;

      await SessionService.signalWorkerDone();
      exit(_exitCode);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, viewport) {
            final padding = MediaQuery.of(context).padding;
            final safeVerticalPadding = padding.top + padding.bottom;
            final effectiveBaseHeight = _baseHeight - safeVerticalPadding;
            final canRenderOneToOne =
                viewport.maxWidth >= _baseWidth && viewport.maxHeight >= effectiveBaseHeight;

            Widget content() => Center(
                  child: _showDoneButton
                      ? ElevatedButton(
                          onPressed: () async {
                            await SessionService.signalWorkerDone();
                            exit(_exitCode);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFCC66FF),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(120, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: 12,
                          ),
                          child: const Text(
                            'Done',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                );

            return SizedBox(
              width: viewport.maxWidth,
              height: viewport.maxHeight - safeVerticalPadding,
              child: canRenderOneToOne
                  ? Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: _baseWidth,
                        height: effectiveBaseHeight,
                        child: content(),
                      ),
                    )
                  : FittedBox(
                      fit: BoxFit.contain,
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: _baseWidth,
                        height: effectiveBaseHeight,
                        child: content(),
                      ),
                    ),
            );
          },
        ),
      ),
    );
  }
}


