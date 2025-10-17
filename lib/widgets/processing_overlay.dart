import 'package:flutter/material.dart';

/// Processing Overlay - Replicates legacy app's WaitingOverlay
/// Shows full-screen overlay with animation during file processing
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

  @override
  void initState() {
    super.initState();
    
    // Initialize animations (exactly like legacy app's animation)
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
    
    // Start animation
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: const Color(0xFF0F172A), // Dark background
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return FadeTransition(
              opacity: _fadeAnimation,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Spinning loader icon
                      ScaleTransition(
                        scale: _scaleAnimation,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                            strokeWidth: 4,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color(0xFF7C3AED), // Purple accent color
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Main title
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
                      // Subtitle
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
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Done Overlay - Replicates legacy app's DoneOverlay
/// Shows "Done" button after processing is complete
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
    
    // Initialize animations
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
    
    // Start animation
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

/// Global overlay manager for processing states
class OverlayManager {
  static OverlayEntry? _currentOverlay;
  
  /// Show processing overlay
  static void showProcessing(BuildContext context, String message) {
    hideOverlay(); // Hide any existing overlay
    
    _currentOverlay = OverlayEntry(
      builder: (context) => ProcessingOverlay(message: message),
    );
    
    Overlay.of(context).insert(_currentOverlay!);
  }
  
  /// Show done overlay
  static void showDone(BuildContext context, VoidCallback onDone) {
    hideOverlay(); // Hide any existing overlay
    
    _currentOverlay = OverlayEntry(
      builder: (context) => DoneOverlay(onDone: onDone),
    );
    
    Overlay.of(context).insert(_currentOverlay!);
  }
  
  /// Hide current overlay
  static void hideOverlay() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }
}
