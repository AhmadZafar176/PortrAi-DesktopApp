import 'package:flutter/material.dart';

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

      textDirection: TextDirection.ltr,
    );
  }
}
