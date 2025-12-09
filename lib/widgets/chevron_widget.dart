import 'package:flutter/material.dart';

class ChevronWidget extends StatelessWidget {
  final bool isUpward;
  final Color color;
  final double size;

  const ChevronWidget({
    super.key,
    required this.isUpward,
    required this.color,
    this.size = 12.0,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size * 0.67),
      painter: ChevronPainter(
        isUpward: isUpward,
        color: color,
      ),
    );
  }
}

class ChevronPainter extends CustomPainter {
  final bool isUpward;
  final Color color;

  ChevronPainter({
    required this.isUpward,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final path = Path();
    
    if (isUpward) {

      path.moveTo(size.width / 2, 0);
      path.lineTo(0, size.height);
      path.lineTo(size.width, size.height);
      path.close();
    } else {

      path.moveTo(0, 0);
      path.lineTo(size.width, 0);
      path.lineTo(size.width / 2, size.height);
      path.close();
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is ChevronPainter &&
        (oldDelegate.isUpward != isUpward || oldDelegate.color != color);
  }
}
