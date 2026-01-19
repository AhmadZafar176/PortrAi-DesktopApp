import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'services/session_service.dart';
import 'services/log_service.dart';

class DoneButtonApp extends StatefulWidget {
  const DoneButtonApp({super.key});

  @override
  State<DoneButtonApp> createState() => _DoneButtonAppState();
}

class _DoneButtonAppState extends State<DoneButtonApp> {
  @override
  void initState() {
    super.initState();
    _initWindow();
  }

  Future<void> _initWindow() async {
    await windowManager.ensureInitialized();
    const width = 120.0;
    const height = 48.0;
    double x = 32.0;
    const double y = 16.0;
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      x = (display.size.width - width - 16).toDouble();
    } catch (e) {
      assert(() {
        print('⚠️ DoneButtonApp: failed to get primary display: $e');
        return true;
      }());
    }

    final options = WindowOptions(
      size: const Size(width, height),
      backgroundColor: const Color(0x00000000),
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setSkipTaskbar(true);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setBounds(Rect.fromLTWH(x, y, width, height));
      await windowManager.show();
      await windowManager.focus();
      await LogService.log('DoneButtonApp shown at ($x,$y)');
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Done',
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final token = await SessionService.getActiveSessionToken();
              if (token != null) {
                await SessionService.signalDonePressedToken(token);
              } else {
              await SessionService.signalDonePressed();
              }
              await LogService.log('DoneButton pressed');
              exit(0);
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
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}


