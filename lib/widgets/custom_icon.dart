import 'package:flutter/material.dart';

/// Custom icon widget that ensures proper icon rendering
class CustomIcon extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;
  
  const CustomIcon(
    this.icon, {
    super.key,
    this.size = 24.0,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      size: size,
      color: color,
      // Explicitly set the font family to ensure proper rendering
      textDirection: TextDirection.ltr,
    );
  }
}
