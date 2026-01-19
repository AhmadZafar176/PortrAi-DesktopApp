import 'dart:async';
import 'package:flutter/material.dart';


class ProcessingOverlay extends StatefulWidget {
  final String message;
  final VoidCallback? onCancel;

  const ProcessingOverlay({
    super.key,
    required this.message,
    this.onCancel,
  });

  @override
  State<ProcessingOverlay> createState() => _ProcessingOverlayState();
}

class _ProcessingOverlayState extends State<ProcessingOverlay>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  Timer? _forceCompleteTimer;
  bool _forceStatic = false;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    
    _scaleAnimation = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.elasticOut,
    ));

    _animationController.forward();

    _forceCompleteTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      if (!_animationController.isCompleted) {
        _animationController.value = 1.0;
        setState(() {
          _forceStatic = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _forceCompleteTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    final useStatic = disableAnimations || _forceStatic;

    final body = Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
            SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            strokeWidth: 4,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFF7C3AED),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        widget.message,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Our AI is working its magic. Please wait a moment.',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          color: Colors.white.withOpacity(0.6),
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
    );

    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFF0F172A),
        child: useStatic
            ? body
            : AnimatedBuilder(
                animation: _animationController,
                builder: (context, child) {
                  return FadeTransition(
                    opacity: _fadeAnimation,
                    child: ScaleTransition(
                      scale: _scaleAnimation,
                      child: body,
              ),
            );
          },
        ),
      ),
    );
  }
}


class DoneOverlay extends StatefulWidget {
  final VoidCallback onDone;

  const DoneOverlay({
    super.key,
    required this.onDone,
  });

  @override
  State<DoneOverlay> createState() => _DoneOverlayState();
}

class _DoneOverlayState extends State<DoneOverlay>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));

    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 16,
      right: 16,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SlideTransition(
          position: _slideAnimation,
          child: ElevatedButton(
            onPressed: widget.onDone,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFCC66FF),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 4,
            ),
            child: const Text(
              'Done',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OverlayManager {
  static OverlayEntry? _currentOverlay;

  static void showProcessing(BuildContext context, String message) {
    hideOverlay();
    
    _currentOverlay = OverlayEntry(
      builder: (context) => ProcessingOverlay(message: message),
    );
    
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      _currentOverlay = null;
      return;
    }
    overlay.insert(_currentOverlay!);
  }

  static void showDone(BuildContext context, VoidCallback onDone) {
    hideOverlay();
    
    _currentOverlay = OverlayEntry(
      builder: (context) => DoneOverlay(onDone: onDone),
    );
    
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      _currentOverlay = null;
      return;
    }
    overlay.insert(_currentOverlay!);
  }

  static void hideOverlay() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }
}
